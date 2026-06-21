#!/usr/bin/env bash
# Copyright (c) 2025 AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

set -euo pipefail

script_source="${BASH_SOURCE[0]}"
script_dir="${script_source%/*}"
if [ "$script_dir" = "$script_source" ]; then
	script_dir="."
fi
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

for cmd in grep jq nix; do
	require "$cmd"
done

nix_common_args=(
	--extra-experimental-features "nix-command flakes"
)
if [ -n "${YEET_SOURCE_PATH:-}" ]; then
	if [ ! -d "$YEET_SOURCE_PATH" ]; then
		echo "YEET_SOURCE_PATH is not a directory: $YEET_SOURCE_PATH" >&2
		exit 1
	fi
	yeet_source_path="$(cd "$YEET_SOURCE_PATH" && pwd)"
	nix_common_args+=(--override-input yeet "path:$yeet_source_path")
fi

config_probe="$(
	nix eval "${nix_common_args[@]}" --json ".#nixosConfigurations.yeet-nixos-26_05.config" --apply '
cfg:
let
  serviceNames = [
    "sshd"
    "systemd-networkd"
    "systemd-resolved"
    "yeet-agent"
    "yeet-metadata-hostname"
    "yeet-networkd-metadata"
    "yeet-grow-root"
    "yeet-guest-ready"
  ];
  modprobeUnits = [
    "modprobe@configfs"
    "modprobe@drm"
    "modprobe@efi_pstore"
    "modprobe@fuse"
  ];
  serviceEnabled = builtins.listToAttrs (map
    (name: {
      inherit name;
      value = (builtins.getAttr name cfg.systemd.services).enable;
    })
    serviceNames);
  modprobeEnabled = builtins.listToAttrs (map
    (name: {
      inherit name;
      value = (builtins.getAttr name cfg.systemd.services).enable;
    })
    modprobeUnits);
in {
  nixFeatures = cfg.nix.settings.experimental-features;
  nixPath = cfg.nix.nixPath;
  environmentPathsToLink = cfg.environment.pathsToLink;
  etcTerminfoEnable = cfg.environment.etc.terminfo.enable;
  systemPackages = map builtins.toString cfg.environment.systemPackages;
  bootKernelEnable = cfg.boot.kernel.enable;
  bootModprobeConfigEnable = cfg.boot.modprobeConfig.enable;
  bootKernelModules = cfg.boot.kernelModules;
  modprobeEnabled = modprobeEnabled;
  sshKeysCommand = cfg.services.openssh.authorizedKeysCommand;
  sshAuthorizedKeysFiles = cfg.services.openssh.authorizedKeysFiles;
  hostnameMetadataScript = cfg.systemd.services.yeet-metadata-hostname.script;
  networkdMetadataScript = cfg.systemd.services.yeet-networkd-metadata.script;
  growRootScript = cfg.systemd.services.yeet-grow-root.script;
  growRootBefore = cfg.systemd.services.yeet-grow-root.before;
  serviceEnabled = serviceEnabled;
  yeetAgentExec = cfg.systemd.services.yeet-agent.serviceConfig.ExecStart;
  yeetVmKernelEnable = cfg.services.yeetVmKernel.enable;
  selectedKernelJsonSource = builtins.toString cfg.environment.etc."yeet-vm/kernel/selected.json".source;
}
'
)"

assert_probe() {
	local jq_filter="$1"
	local message="$2"
	printf '%s\n' "$config_probe" | jq -e "$jq_filter" >/dev/null || {
		echo "$message" >&2
		echo "want: $jq_filter" >&2
		echo "got:" >&2
		printf '%s\n' "$config_probe" >&2
		exit 1
	}
}

assert_probe '.nixFeatures | index("nix-command") != null and index("flakes") != null' "nix-command and flakes must be enabled by default"
assert_probe '.nixPath | map(startswith("nixpkgs=")) | any' "nixos-rebuild must find nixpkgs by default"
assert_probe '.nixPath | index("nixos-config=/etc/nixos/configuration.nix") == null' "flake-first image must not wire nixos-config to /etc/nixos/configuration.nix"
assert_probe '.environmentPathsToLink | index("/share/terminfo") != null' "terminfo must be linked into the system profile for Ghostty support"
assert_probe '.etcTerminfoEnable == false' "/etc/terminfo must not be managed as a symlink because make-ext4-fs materializes it as a directory"
for package in rclone rsync iptables nftables curl file iproute2 jq openssh procps wget; do
	assert_probe ".systemPackages | map(tostring) | any(contains(\"$package\"))" "$package must be installed for yeet/catch guest workflows"
done
assert_probe '.systemPackages | map(tostring) | any(test("-git-[0-9]"))' "normal git must be installed for yeet/catch guest workflows"
assert_probe '.systemPackages | map(tostring) | all(contains("git-minimal") | not)' "NixOS image must use normal git rather than gitMinimal"
assert_probe '.bootKernelEnable == false' "NixOS image must not include the default NixOS kernel closure because Firecracker boots the yeet-selected external kernel"
assert_probe '.bootModprobeConfigEnable == true' "NixOS activation expects boot.modprobeConfig for /proc/sys/kernel/modprobe"
assert_probe '.bootKernelModules == []' "default NixOS hardware module requests must be cleared for the yeet microVM kernel"
assert_probe '.modprobeEnabled["modprobe@configfs"] == false and .modprobeEnabled["modprobe@drm"] == false and .modprobeEnabled["modprobe@efi_pstore"] == false and .modprobeEnabled["modprobe@fuse"] == false' "modprobe@ units must be disabled by default in the yeet microVM profile"
assert_probe '.sshKeysCommand == "none"' "unexpected NixOS AuthorizedKeysCommand"
assert_probe '.sshAuthorizedKeysFiles | index("/etc/yeet-vm/authorized_keys.d/%u") != null' "NixOS SSH keys must include yeet metadata keys"
assert_probe '.hostnameMetadataScript | contains("system_nix=/etc/nixos/system.nix") and contains("grep -Eq") and contains("sed -n")' "yeet-metadata-hostname must respect the user-owned NixOS hostname"
assert_probe '.hostnameMetadataScript | contains("/etc/yeet-vm/hostname")' "yeet-metadata-hostname must keep metadata hostname fallback for unseeded images"
assert_probe '.networkdMetadataScript | contains("compgen") | not' "yeet-networkd-metadata must not depend on Bash-only compgen"
assert_probe '.growRootScript | contains("resize2fs \"$root_source\"")' "yeet-grow-root must resize the root source"
assert_probe '.growRootBefore | index("yeet-guest-ready.service") != null' "yeet-grow-root must run before yeet guest readiness"
assert_probe '.serviceEnabled | all(.[]; . == true)' "expected core yeet NixOS services to be enabled"
assert_probe '.yeetAgentExec == "/usr/local/lib/yeet-vm/yeet-agent"' "unexpected yeet-agent ExecStart"
assert_probe '.yeetVmKernelEnable == true' "fresh NixOS image must enable the yeet VM kernel selector"
assert_probe '.selectedKernelJsonSource | contains("/share/yeet-vm/kernel/selected.json")' "/etc/yeet-vm/kernel/selected.json must be configured from the yeet kernel package"
grep -Fq 'ln -s ${yeetAgent}/bin/yeet-agent ./files/usr/local/lib/yeet-vm/yeet-agent' "$repo_root/flake.nix" || {
	echo "NixOS rootfs must include /usr/local/lib/yeet-vm/yeet-agent" >&2
	exit 1
}
grep -Fq 'import ./nix/make-ext4-rootfs.nix' "$repo_root/flake.nix" || {
	echo "NixOS rootfs must use the yeet ext4 builder with explicit inode headroom" >&2
	exit 1
}
grep -Fq 'mkfs.ext4 -N $mkfsInodes' "$repo_root/nix/make-ext4-rootfs.nix" || {
	echo "NixOS ext4 builder must request explicit mkfs inode headroom" >&2
	exit 1
}
for install_path in \
	'install -m 0644 ${nixos-guest-config}/README.md ./files/etc/nixos/README.md' \
	'install -m 0644 ${nixos-guest-config}/flake.nix ./files/etc/nixos/flake.nix' \
	'install -m 0644 ${nixos-guest-config}/flake.lock ./files/etc/nixos/flake.lock' \
	'install -m 0644 ${nixos-guest-config}/system.nix ./files/etc/nixos/system.nix' \
	'install -m 0644 ${nixos-guest-config}/yeet/vm.nix ./files/etc/nixos/yeet/vm.nix' \
	'install -m 0644 ${nixos-guest-config}/yeet/assets/xterm-ghostty.terminfo ./files/etc/nixos/yeet/assets/xterm-ghostty.terminfo' \
	'install -m 0644 ${nixosSystem.config.environment.etc."yeet-vm/kernel/selected.json".source} ./files/etc/yeet-vm/kernel/selected.json'
do
	grep -Fq "$install_path" "$repo_root/flake.nix" || {
		echo "NixOS rootfs must install $install_path" >&2
		exit 1
	}
done
if grep -Fq './files/etc/nixos/configuration.nix' "$repo_root/flake.nix"; then
	echo "NixOS rootfs must not copy /etc/nixos/configuration.nix" >&2
	exit 1
fi
for flake_content in \
	'nixosConfigurations.yeet-vm' \
	'github:yeetrun/yeet-vm-images?dir=kernel-packages' \
	'./yeet/vm.nix' \
	'./system.nix' \
	'services.yeetVmKernel.enable = true;'
do
	grep -Fq "$flake_content" "$repo_root/nixos/flake.nix" || {
		echo "NixOS guest flake must contain $flake_content" >&2
		exit 1
	}
done
for system_package in \
	htop \
	vim
do
	grep -Eq "^[[:space:]]*${system_package}([[:space:]]|$)" "$repo_root/nixos/system.nix" || {
		echo "NixOS user-visible system.nix must list $system_package" >&2
		exit 1
	}
done
for internal_package in \
	rclone \
	rsync \
	iptables \
	nftables \
	curl \
	file \
	git \
	gitMinimal \
	iproute2 \
	jq \
	openssh \
	procps \
	wget
do
	if grep -Eq "^[[:space:]]*${internal_package}([[:space:]]|$)" "$repo_root/nixos/system.nix"; then
		echo "NixOS user-visible system.nix must not list internal yeet package $internal_package" >&2
		exit 1
	fi
done

override_probe="$(
	nix eval --impure "${nix_common_args[@]}" --json --expr '
let
  flake = builtins.getFlake "path:'"$repo_root"'";
  modprobeUnits = [
    "modprobe@configfs"
    "modprobe@drm"
    "modprobe@efi_pstore"
    "modprobe@fuse"
  ];
  cfg = (flake.nixosConfigurations.yeet-nixos-26_05.extendModules {
    modules = [
      ({ lib, ... }: {
        boot.kernel.enable = true;
        boot.kernelModules = lib.mkForce [ "dummy" ];
        systemd.services = builtins.listToAttrs (map
          (name: {
            inherit name;
            value = {
              enable = true;
              wantedBy = [ "sysinit.target" ];
            };
          })
          modprobeUnits);
      })
    ];
  }).config;
in {
  bootKernelModules = cfg.boot.kernelModules;
  systemdModulesLoadEnable = cfg.systemd.services.systemd-modules-load.enable;
  systemdModulesLoadWantedBy = cfg.systemd.services.systemd-modules-load.wantedBy;
  modprobeUnits = builtins.listToAttrs (map
    (name:
      let
        service = builtins.getAttr name cfg.systemd.services;
      in
      {
        inherit name;
        value = {
          enable = service.enable;
          wantedBy = service.wantedBy;
        };
      })
    modprobeUnits);
}
'
)"
printf '%s\n' "$override_probe" | jq -e '
  (.bootKernelModules | index("dummy") != null) and
  .systemdModulesLoadEnable == true and
  (.systemdModulesLoadWantedBy | index("multi-user.target") != null) and
  (.modprobeUnits | length == 4) and
  ([.modprobeUnits[] | select(.enable == true and (.wantedBy | index("sysinit.target") != null))] | length == 4)
' >/dev/null || {
	echo "NixOS yeet microVM defaults must remain overrideable by user configuration" >&2
	printf '%s\n' "$override_probe" >&2
	exit 1
}

echo "NixOS 26.05 yeet microVM profile verified"
