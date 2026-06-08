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

for unit in \
	'modprobe@configfs' \
	'modprobe@drm' \
	'modprobe@efi_pstore' \
	'modprobe@fuse'
do
	assert_json "systemd.services.\"${unit}\".enable" '. == false' "$unit must be disabled in the no-module microVM profile"
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
  cfg = (flake.nixosConfigurations.yeet-nixos-26_05.extendModules {
    modules = [
      ({ ... }: {
        boot.kernelModules = [ "dummy" ];
        systemd.services."modprobe@fuse" = {
          enable = true;
          wantedBy = [ "sysinit.target" ];
        };
      })
    ];
  }).config;
in {
  bootKernelModules = cfg.boot.kernelModules;
  systemdModulesLoadEnable = cfg.systemd.services.systemd-modules-load.enable;
  systemdModulesLoadWantedBy = cfg.systemd.services.systemd-modules-load.wantedBy;
  modprobeFuseEnable = cfg.systemd.services."modprobe@fuse".enable;
  modprobeFuseWantedBy = cfg.systemd.services."modprobe@fuse".wantedBy;
}
'
)"
printf '%s\n' "$override_probe" | jq -e '
  (.bootKernelModules | index("dummy") != null) and
  .systemdModulesLoadEnable == true and
  (.systemdModulesLoadWantedBy | index("multi-user.target") != null) and
  .modprobeFuseEnable == true and
  (.modprobeFuseWantedBy | index("sysinit.target") != null)
' >/dev/null || {
	echo "NixOS yeet microVM defaults must remain overrideable by user configuration" >&2
	printf '%s\n' "$override_probe" >&2
	exit 1
}

echo "NixOS 26.05 yeet microVM profile verified"
