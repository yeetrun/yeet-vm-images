#!/usr/bin/env bash
# Copyright (c) 2025 AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

nix_eval_json() {
	local attr="$1"
	nix eval --extra-experimental-features "nix-command flakes" --json ".#nixosConfigurations.yeet-nixos-26_05.config.${attr}"
}

nix_eval_raw() {
	local attr="$1"
	nix eval --extra-experimental-features "nix-command flakes" --raw ".#nixosConfigurations.yeet-nixos-26_05.config.${attr}"
}

assert_json() {
	local attr="$1"
	local jq_filter="$2"
	local message="$3"
	nix_eval_json "$attr" | jq -e "$jq_filter" >/dev/null || {
		echo "$message" >&2
		echo "attr: $attr" >&2
		echo "want: $jq_filter" >&2
		echo "got:" >&2
		nix_eval_json "$attr" >&2
		exit 1
	}
}

assert_raw_equals() {
	local attr="$1"
	local want="$2"
	local got
	got="$(nix_eval_raw "$attr")"
	if [ "$got" != "$want" ]; then
		echo "unexpected $attr: got $got, want $want" >&2
		exit 1
	fi
}

assert_json "nix.settings.experimental-features" 'index("nix-command") != null and index("flakes") != null' "nix-command and flakes must be enabled by default"
assert_json "nix.nixPath" 'index("nixpkgs=flake:nixpkgs") != null and index("nixos-config=/etc/nixos/configuration.nix") != null' "nixos-rebuild must find nixpkgs and /etc/nixos/configuration.nix by default"
assert_json "environment.pathsToLink" 'index("/share/terminfo") != null' "terminfo must be linked into the system profile for Ghostty support"
assert_json "environment.etc.terminfo.enable" '. == false' "/etc/terminfo must not be managed as a symlink because make-ext4-fs materializes it as a directory"
assert_json "boot.modprobeConfig.enable" '. == true' "NixOS activation expects boot.modprobeConfig for /proc/sys/kernel/modprobe"
assert_json "boot.kernelModules" '. == []' "default NixOS hardware module requests must be cleared for the yeet microVM kernel"

for unit in \
	'modprobe@configfs' \
	'modprobe@drm' \
	'modprobe@efi_pstore' \
	'modprobe@fuse'
do
	assert_json "systemd.services.\"${unit}\".enable" '. == false' "$unit must be disabled by default in the yeet microVM profile"
done

assert_raw_equals "services.openssh.authorizedKeysCommand" "none"
nix_eval_json "services.openssh.authorizedKeysFiles" \
	| jq -e 'index("/etc/yeet-vm/authorized_keys.d/%u") != null' >/dev/null

networkd_metadata_script="$(nix_eval_raw "systemd.services.yeet-networkd-metadata.script")"
if printf '%s\n' "$networkd_metadata_script" | grep -q 'compgen'; then
	echo "yeet-networkd-metadata must not depend on Bash-only compgen" >&2
	exit 1
fi

grow_root_script="$(nix_eval_raw "systemd.services.yeet-grow-root.script")"
printf '%s\n' "$grow_root_script" | grep -q 'resize2fs "$root_source"'
nix_eval_json "systemd.services.yeet-grow-root.before" \
	| jq -e 'index("yeet-guest-ready.service") != null' >/dev/null

for service in \
	"sshd" \
	"systemd-networkd" \
	"systemd-resolved" \
	"yeet-metadata-hostname" \
	"yeet-networkd-metadata" \
	"yeet-grow-root" \
	"yeet-guest-ready"
do
	nix_eval_json "systemd.services.${service}.enable" | jq -e '. == true' >/dev/null || {
		echo "expected service ${service} to be enabled" >&2
		exit 1
	}
done

override_probe="$(
	nix eval --impure --extra-experimental-features "nix-command flakes" --json --expr '
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
