#!/usr/bin/env bash
# Copyright (c) 2025 AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

set -euo pipefail

version="${YEET_VM_IMAGE_VERSION:-nixos-26.05-amd64-v7}"
out_dir="${1:-dist/$version}"
work_dir="${YEET_VM_IMAGE_WORK_DIR:-}"
kernel_path="${YEET_VM_KERNEL_PATH:-}"
kernel_version="${YEET_VM_KERNEL_VERSION:-}"
yeet_source_path="${YEET_SOURCE_PATH:-}"
firecracker_version="${FIRECRACKER_VERSION:-v1.14.3}"
firecracker_arch="${FIRECRACKER_ARCH:-x86_64}"
firecracker_tgz="firecracker-${firecracker_version}-${firecracker_arch}.tgz"
firecracker_url="${FIRECRACKER_URL:-https://github.com/firecracker-microvm/firecracker/releases/download/${firecracker_version}/${firecracker_tgz}}"
zstd_level="${ZSTD_LEVEL:-10}"

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

for cmd in awk chmod cp curl date dumpe2fs e2fsck file find jq mkdir mktemp nix readlink resize2fs sha256sum stat tar tune2fs zstd; do
	require "$cmd"
done

if [ -z "$kernel_path" ]; then
	echo "YEET_VM_KERNEL_PATH is required" >&2
	exit 1
fi
if [ ! -r "$kernel_path" ]; then
	echo "YEET_VM_KERNEL_PATH is not readable: $kernel_path" >&2
	exit 1
fi
if [ -z "$kernel_version" ]; then
	kernel_version="$(basename "$kernel_path")"
fi

if [ -z "$work_dir" ]; then
	work_dir="$(mktemp -d)"
	cleanup_work=1
else
	mkdir -p "$work_dir"
	cleanup_work=0
fi

cleanup() {
	if [ "${cleanup_work:-0}" = 1 ]; then
		rm -rf "$work_dir"
	fi
}
trap cleanup EXIT

mkdir -p "$out_dir"

nix_common_args=(
	--extra-experimental-features "nix-command flakes"
)
if [ -n "$yeet_source_path" ]; then
	nix_common_args+=(--override-input yeet "path:$yeet_source_path")
fi

nix_flake_metadata_json() {
	nix flake metadata "${nix_common_args[@]}" --json .
}

echo "Building NixOS 26.05 rootfs..."
nix build "${nix_common_args[@]}" --out-link "$work_dir/rootfs-result" .#nixos-26_05-rootfs
rootfs_result="$(readlink -f "$work_dir/rootfs-result")"
if [ ! -s "$rootfs_result" ]; then
	echo "NixOS rootfs build did not produce a file: $rootfs_result" >&2
	exit 1
fi
install -m 0644 "$rootfs_result" "$out_dir/rootfs.ext4"
nix build "${nix_common_args[@]}" --out-link "$work_dir/yeet-init-result" .#yeet-init
yeet_init_result="$(readlink -f "$work_dir/yeet-init-result")"

run_e2fsck() {
	local rootfs="$1"
	local status

	set +e
	e2fsck -fy "$rootfs"
	status=$?
	set -e

	case "$status" in
	0 | 1)
		;;
	*)
		echo "e2fsck failed after rootfs feature normalization: exit $status" >&2
		exit "$status"
		;;
	esac
}

normalize_rootfs_ext4_features() {
	local rootfs="$1"
	local features

	features="$(dumpe2fs -h "$rootfs" 2>/dev/null | awk -F: '/Filesystem features/ { print $2; exit }')"
	if printf '%s\n' "$features" | grep -qw orphan_file; then
		echo "Disabling ext4 orphan_file for LTS host e2fsprogs compatibility..."
		tune2fs -O ^orphan_file "$rootfs" >/dev/null
		run_e2fsck "$rootfs"
	fi

	features="$(dumpe2fs -h "$rootfs" 2>/dev/null | awk -F: '/Filesystem features/ { print $2; exit }')"
	if printf '%s\n' "$features" | grep -Eq '(^|[[:space:]])orphan_file($|[[:space:]])|(^|[[:space:]])FEATURE_'; then
		echo "rootfs ext4 features are not compatible with LTS host tooling: $features" >&2
		exit 1
	fi
}

normalize_rootfs_ext4_features "$out_dir/rootfs.ext4"

echo "Downloading Firecracker $firecracker_version..."
curl -fL --retry 3 -o "$work_dir/$firecracker_tgz" "$firecracker_url"
tar xzf "$work_dir/$firecracker_tgz" -C "$work_dir"
fc_dir="$work_dir/release-${firecracker_version}-${firecracker_arch}"
(
	cd "$fc_dir"
	sha256sum -c --ignore-missing SHA256SUMS
)

install -m 0644 "$kernel_path" "$out_dir/vmlinux"
if [ -r "$(dirname "$kernel_path")/kernel.config" ]; then
	install -m 0644 "$(dirname "$kernel_path")/kernel.config" "$out_dir/kernel.config"
fi
install -m 0755 "$fc_dir/firecracker-${firecracker_version}-${firecracker_arch}" "$out_dir/firecracker"

echo "Compressing rootfs..."
zstd -T0 "-$zstd_level" -f --no-progress -o "$out_dir/rootfs.ext4.zst" "$out_dir/rootfs.ext4"

rootfs_size="$(stat -c %s "$out_dir/rootfs.ext4")"
rootfs_sha="$(sha256sum "$out_dir/rootfs.ext4.zst" | awk '{ print $1 }')"
kernel_sha="$(sha256sum "$out_dir/vmlinux" | awk '{ print $1 }')"
firecracker_sha="$(sha256sum "$out_dir/firecracker" | awk '{ print $1 }')"
source_image_sha="$(sha256sum "$out_dir/rootfs.ext4" | awk '{ print $1 }')"
build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
flake_metadata="$(nix_flake_metadata_json)"
nixpkgs_rev="$(printf '%s' "$flake_metadata" | jq -r '.locks.nodes.nixpkgs.locked.rev // empty')"
if [ -n "$yeet_source_path" ] && git -C "$yeet_source_path" rev-parse HEAD >/dev/null 2>&1; then
	yeet_rev="$(git -C "$yeet_source_path" rev-parse HEAD)"
else
	yeet_rev="$(printf '%s' "$flake_metadata" | jq -r '.locks.nodes.yeet.locked.rev // empty')"
fi
guest_init_sha="$(sha256sum "$yeet_init_result/bin/yeet-init" | awk '{ print $1 }')"

kernel_config_checksum_line=""
if [ -f "$out_dir/kernel.config" ]; then
	kernel_config_sha="$(sha256sum "$out_dir/kernel.config" | awk '{ print $1 }')"
	kernel_config_checksum_line='    "kernel.config": "'"$kernel_config_sha"'",'
fi

cat >"$out_dir/manifest.json" <<JSON
{
  "name": "yeet-nixos-26.05",
  "version": "$version",
  "architecture": "x86_64",
  "distro": "nixos",
  "distro_version": "26.05",
  "default_user": "nixos",
  "image_profile": "nixos",
  "kernel_policy": "yeet-managed",
  "snap_support": false,
  "guest_init": "/usr/local/lib/yeet-vm/yeet-init",
  "guest_system_init": "/run/current-system/init",
  "guest_init_sha256": "$guest_init_sha",
  "metadata_driver": "nixos",
  "kernel": "vmlinux",
  "rootfs": "rootfs.ext4.zst",
  "firecracker": "firecracker",
  "rootfs_size": $rootfs_size,
  "kernel_version": "$kernel_version",
  "provenance": {
    "build_time": "$build_time",
    "nixpkgs_ref": "nixos-26.05",
    "nixpkgs_rev": "$nixpkgs_rev",
    "yeet_rev": "$yeet_rev",
    "nixos_rootfs_sha256": "$source_image_sha",
    "firecracker_version": "$firecracker_version",
    "firecracker_url": "$firecracker_url"
  },
  "checksums": {
    "vmlinux": "$kernel_sha",
$kernel_config_checksum_line
    "rootfs.ext4.zst": "$rootfs_sha",
    "firecracker": "$firecracker_sha"
  }
}
JSON

(
	cd "$out_dir"
	checksum_files=(manifest.json vmlinux)
	if [ -f kernel.config ]; then
		checksum_files+=(kernel.config)
	fi
	checksum_files+=(rootfs.ext4.zst firecracker)
	sha256sum "${checksum_files[@]}" >checksums.txt
)

rm -f "$out_dir/rootfs.ext4"

echo "Wrote NixOS VM image bundle to $out_dir"
echo "Version: $version"
echo "Kernel: $kernel_version"
