#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal source.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
renderer="$repo_root/scripts/render-guest-manifest.sh"
builder="$repo_root/scripts/build-nixos-26.05.sh"
workflow="$repo_root/.github/workflows/build-nixos-26.05.yml"
system_config="$repo_root/nixos/system.nix"
vm_module="$repo_root/nixos/yeet/vm.nix"

printf 'compressed NixOS rootfs\n' >"$tmp_dir/rootfs.ext4.zst"
rootfs_sha="$(sha256sum "$tmp_dir/rootfs.ext4.zst" | awk '{ print $1 }')"
"$renderer" \
	--guest-base-id guest-nixos-26.05-amd64-v1 \
	--os nixos \
	--os-version 26.05 \
	--architecture amd64 \
	--rootfs "$tmp_dir/rootfs.ext4.zst" \
	--uncompressed-bytes 4294967296 \
	--default-kernel-channel stable \
	--source-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
	--workflow-run-url https://github.com/yeetrun/yeet-vm-images/actions/runs/123456792 \
	--out "$tmp_dir/guest-manifest.json"

jq -e --arg rootfs_sha "$rootfs_sha" '
	.schema_version == 1 and
	.guest_base_id == "guest-nixos-26.05-amd64-v1" and
	.os == "nixos" and
	.os_version == "26.05" and
	.architecture == "amd64" and
	.rootfs.url == "https://github.com/yeetrun/yeet-vm-images/releases/download/guest-nixos-26.05-amd64-v1/rootfs.ext4.zst" and
	.rootfs.sha256 == $rootfs_sha and
	.default_kernel_channel == "stable" and
	([.. | objects | keys[]] | all(. != "firecracker" and . != "jailer" and . != "vmlinux"))
' "$tmp_dir/guest-manifest.json" >/dev/null

for forbidden in \
	'firecracker_version:' \
	'kernel_version:' \
	'upstream_kernel_version:' \
	'kernel_source_url:' \
	'kernel_source_sha256:' \
	'kernel_config_url:' \
	'overwrite_release:' \
	'publish_latest_alias:' \
	'latest_alias:' \
	'build-linux-kernel.sh' \
	'download-kernel-release.sh' \
	'YEET_VM_KERNEL_PATH' \
	'FIRECRACKER_VERSION'
do
	if grep -Fq "$forbidden" "$workflow"; then
		echo "NixOS guest-base workflow still contains monolithic input or behavior: $forbidden" >&2
		exit 1
	fi
done

for required in \
	'guest_base_id:' \
	'yeet_ref:' \
	'kernel_release:' \
	'kernel_manifest_sha256:' \
	'zstd_level:' \
	'yeet_vm_images_ref:' \
	'scripts/update-guest-catalog.sh' \
	'scripts/publish-guest-base-assets.sh' \
	'--channel candidate' \
	'actions/create-github-app-token@' \
	'environment: firecracker-runtime-promotion' \
	'gh pr create'
do
	grep -Fq -- "$required" "$workflow"
done
if grep -Fq 'peter-evans/create-pull-request@' "$workflow"; then
	echo "NixOS candidate promotion still relies on the organization-blocked Actions token" >&2
	exit 1
fi
for ignored in '.build-work/' 'dist/' 'yeet-src/'; do
	grep -Fxq -- "$ignored" "$repo_root/.gitignore"
done

for forbidden in \
	'Downloading Firecracker' \
	'firecracker_tgz=' \
	'firecracker_url=' \
	'YEET_VM_KERNEL_PATH' \
	'install -m 0644 "$kernel_path" "$out_dir/vmlinux"' \
	'install -m 0755 "$fc_dir/firecracker' \
	'install -m 0755 "$fc_dir/jailer' \
	'"firecracker": "firecracker"' \
	'"jailer": "jailer"'
do
	if grep -Fq "$forbidden" "$builder"; then
		echo "NixOS guest-base builder still emits a host artifact: $forbidden" >&2
		exit 1
	fi
done

grep -Fq 'github:yeetrun/yeet-vm-images/${guest_kernel_ref}?dir=kernel-packages' "$builder"
grep -Fq 'guest-manifest.json' "$builder"
grep -Fq 'provenance.json' "$builder"
grep -Fq 'rootfs.ext4.zst' "$builder"
if grep -Eq 'selected[.]json.*(curl|nix build|exec)|(curl|nix build|exec).*selected[.]json' "$builder"; then
	echo "NixOS builder treats guest selector metadata as artifact authority" >&2
	exit 1
fi

grep -Fq 'data-only request' "$system_config"
grep -Fq 'Catch validates it against the trusted' "$system_config"
grep -Fq 'host kernel catalog before staging anything' "$system_config"
grep -Fq '"d /etc/yeet-vm/kernel 0755 root root -"' "$vm_module"
grep -Fq 'The guest owns only the data-only selector request' "$vm_module"

printf '%s\n' 'NixOS component guest-base tests passed'
