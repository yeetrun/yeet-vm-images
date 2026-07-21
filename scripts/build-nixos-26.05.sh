#!/usr/bin/env bash
# Copyright (c) 2025 AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

set -euo pipefail

guest_base_id="${YEET_VM_GUEST_BASE_ID:-}"
out_dir="${1:-dist/$guest_base_id}"
work_dir="${YEET_VM_IMAGE_WORK_DIR:-}"
kernel_release="${YEET_VM_KERNEL_RELEASE_ID:-}"
kernel_manifest_sha256="${YEET_VM_KERNEL_MANIFEST_SHA256:-}"
yeet_source_path="${YEET_SOURCE_PATH:-}"
images_source_rev="${YEET_VM_IMAGES_SOURCE_REV:-}"
workflow_run_url="${YEET_VM_WORKFLOW_RUN_URL:-}"
guest_kernel_ref="${YEET_VM_IMAGES_REF:-}"
zstd_level="${ZSTD_LEVEL:-10}"

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

for cmd in awk cat chmod cp date debugfs dirname dumpe2fs e2fsck find git grep install jq mkdir mktemp nix readlink resize2fs rm sha256sum stat tune2fs zstd; do
	require "$cmd"
done

if ! [[ "$guest_base_id" =~ ^guest-nixos-26[.]05-amd64-v[1-9][0-9]*$ ]]; then
	echo "YEET_VM_GUEST_BASE_ID must be guest-nixos-26.05-amd64-vN: $guest_base_id" >&2
	exit 1
fi
if ! [[ "$kernel_release" =~ ^kernel-linux-([0-9]+[.][0-9]+([.][0-9]+)*)-yeet-v([1-9][0-9]*)$ ]]; then
	echo "YEET_VM_KERNEL_RELEASE_ID must be an immutable kernel release: $kernel_release" >&2
	exit 1
fi
kernel_upstream_version="${BASH_REMATCH[1]}"
kernel_version="linux-${kernel_upstream_version}-yeet"
if ! [[ "$kernel_manifest_sha256" =~ ^[0-9a-f]{64}$ ]]; then
	echo "YEET_VM_KERNEL_MANIFEST_SHA256 must be a lowercase SHA-256" >&2
	exit 1
fi
for revision in "$images_source_rev" "$guest_kernel_ref"; do
	if ! [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
		echo "image source and kernel package refs must be full Git commits" >&2
		exit 1
	fi
done
if ! [[ "$workflow_run_url" =~ ^https://github[.]com/yeetrun/yeet-vm-images/actions/runs/[1-9][0-9]*$ ]]; then
	echo "YEET_VM_WORKFLOW_RUN_URL must identify a yeet-vm-images Actions run" >&2
	exit 1
fi

if [ -z "$work_dir" ]; then
	work_dir="$(mktemp -d)"
	cleanup_work=1
else
	mkdir -p "$work_dir"
	cleanup_work=0
fi
generated_inputs_dir="$(mktemp -d)"

cleanup() {
	rm -rf "$generated_inputs_dir"
	if [ "${cleanup_work:-0}" = 1 ]; then
		rm -rf "$work_dir"
	fi
}
trap cleanup EXIT

mkdir -p "$out_dir"
if [ -n "$(find "$out_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
	echo "guest-base output directory must be empty: $out_dir" >&2
	exit 1
fi

nix_common_args=(
	--extra-experimental-features "nix-command flakes"
)
if [ -n "$yeet_source_path" ]; then
	nix_common_args+=(--override-input yeet "path:$yeet_source_path")
fi
nix_common_args+=(--override-input yeet-vm-kernel "github:yeetrun/yeet-vm-images/${guest_kernel_ref}?dir=kernel-packages")

nix_flake_metadata_json() {
	nix flake metadata "${nix_common_args[@]}" --json .
}

guest_config_dir="$generated_inputs_dir/nixos-guest-config"
rm -rf "$guest_config_dir"
mkdir -p "$guest_config_dir"
cp -R nixos/. "$guest_config_dir/"
nix --extra-experimental-features "nix-command flakes" flake lock "$guest_config_dir" \
	--override-input yeet-vm-kernel "github:yeetrun/yeet-vm-images/${guest_kernel_ref}?dir=kernel-packages" \
	--output-lock-file "$guest_config_dir/flake.lock"
nix_common_args+=(--override-input nixos-guest-config "path:$guest_config_dir")
echo "Pinned guest yeet-vm-kernel input to ${guest_kernel_ref}"

echo "Building NixOS 26.05 rootfs..."
nix build "${nix_common_args[@]}" --print-build-logs --out-link "$work_dir/rootfs-result" .#packages.x86_64-linux.nixos-26_05-rootfs
rootfs_result="$(readlink -f "$work_dir/rootfs-result")"
if [ ! -s "$rootfs_result" ]; then
	echo "NixOS rootfs build did not produce a file: $rootfs_result" >&2
	exit 1
fi
install -m 0644 "$rootfs_result" "$out_dir/rootfs.ext4"
nix build "${nix_common_args[@]}" --print-build-logs --out-link "$work_dir/yeet-init-result" .#packages.x86_64-linux.yeet-init
yeet_init_result="$(readlink -f "$work_dir/yeet-init-result")"
nix build "${nix_common_args[@]}" --print-build-logs --out-link "$work_dir/yeet-agent-result" .#packages.x86_64-linux.yeet-agent
yeet_agent_result="$(readlink -f "$work_dir/yeet-agent-result")"

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

validate_rootfs_free_space() {
	local rootfs="$1"
	local free_blocks
	local block_size
	local free_mib

	free_blocks="$(dumpe2fs -h "$rootfs" 2>/dev/null | awk -F: '/Free blocks/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')"
	block_size="$(dumpe2fs -h "$rootfs" 2>/dev/null | awk -F: '/Block size/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')"
	if [ -z "$free_blocks" ] || [ -z "$block_size" ]; then
		echo "could not inspect NixOS rootfs free space" >&2
		exit 1
	fi
	free_mib=$((free_blocks * block_size / 1024 / 1024))
	if [ "$free_mib" -lt 256 ]; then
		echo "NixOS rootfs must have at least 256 MiB free before first boot activation, got ${free_mib} MiB" >&2
		exit 1
	fi
}

normalize_rootfs_ext4_features "$out_dir/rootfs.ext4"
validate_rootfs_free_space "$out_dir/rootfs.ext4"

rootfs_size="$(stat -c %s "$out_dir/rootfs.ext4")"
customized_rootfs_sha="$(sha256sum "$out_dir/rootfs.ext4" | awk '{ print $1 }')"
debugfs -R "cat /etc/yeet-vm/kernel/selected.json" "$out_dir/rootfs.ext4" 2>/dev/null |
	jq -e \
		--arg version "$kernel_version" \
		--arg release "$kernel_release" \
		--arg manifest "$kernel_manifest_sha256" '
		.schema_version == 2 and
		.version == $version and
		.release_id == $release and
		.manifest_sha256 == $manifest and
		(.kernel | startswith("/nix/store/") and endswith("/lib/yeet-vm/kernels/" + $version + "/vmlinux")) and
		(.kernel_config | startswith("/nix/store/") and endswith("/lib/yeet-vm/kernels/" + $version + "/kernel.config")) and
		(.sha256.vmlinux | test("^[0-9a-f]{64}$")) and
		(.sha256["kernel.config"] | test("^[0-9a-f]{64}$"))
	' >/dev/null || {
		echo "NixOS guest selector does not match the requested immutable kernel" >&2
		exit 1
	}

echo "Compressing rootfs..."
zstd -T0 "-$zstd_level" -f --no-progress -o "$out_dir/rootfs.ext4.zst" "$out_dir/rootfs.ext4"

build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
flake_metadata="$(nix_flake_metadata_json)"
nixpkgs_rev="$(printf '%s' "$flake_metadata" | jq -r '.locks.nodes.nixpkgs.locked.rev // empty')"
if [ -n "$yeet_source_path" ]; then
	if ! yeet_rev="$(git -C "$yeet_source_path" rev-parse HEAD 2>/dev/null)"; then
		echo "YEET_SOURCE_PATH must point to a git checkout so manifest provenance can record yeet_rev" >&2
		exit 1
	fi
else
	yeet_rev="$(printf '%s' "$flake_metadata" | jq -r '.locks.nodes.yeet.locked.rev // empty')"
fi
guest_init_sha="$(sha256sum "$yeet_init_result/bin/yeet-init" | awk '{ print $1 }')"
guest_agent_sha="$(sha256sum "$yeet_agent_result/bin/yeet-agent" | awk '{ print $1 }')"
guest_flake_lock_sha="$(sha256sum "$guest_config_dir/flake.lock" | awk '{ print $1 }')"

"$(cd "$(dirname "$0")" && pwd)/render-guest-manifest.sh" \
	--guest-base-id "$guest_base_id" \
	--os nixos \
	--os-version 26.05 \
	--architecture amd64 \
	--rootfs "$out_dir/rootfs.ext4.zst" \
	--uncompressed-bytes "$rootfs_size" \
	--default-kernel-channel stable \
	--source-commit "$images_source_rev" \
	--workflow-run-url "$workflow_run_url" \
	--out "$out_dir/guest-manifest.json"

jq -n \
	--arg guest_base_id "$guest_base_id" \
	--arg build_time "$build_time" \
	--arg images_source_rev "$images_source_rev" \
	--arg workflow_run_url "$workflow_run_url" \
	--arg nixpkgs_rev "$nixpkgs_rev" \
	--arg yeet_rev "$yeet_rev" \
	--arg guest_kernel_ref "$guest_kernel_ref" \
	--arg guest_flake_lock_sha256 "$guest_flake_lock_sha" \
	--arg customized_rootfs_sha256 "$customized_rootfs_sha" \
	--arg guest_init_sha256 "$guest_init_sha" \
	--arg guest_agent_sha256 "$guest_agent_sha" \
	--arg kernel_release "$kernel_release" \
	--arg kernel_manifest_sha256 "$kernel_manifest_sha256" '
	{
		schema_version: 1,
		guest_base_id: $guest_base_id,
		build_time: $build_time,
		source: {
			images_commit: $images_source_rev,
			workflow_run_url: $workflow_run_url,
			nixpkgs_ref: "nixos-26.05",
			nixpkgs_commit: $nixpkgs_rev,
			yeet_commit: $yeet_rev,
			kernel_package_commit: $guest_kernel_ref,
			guest_flake_lock_sha256: $guest_flake_lock_sha256,
			customized_rootfs_sha256: $customized_rootfs_sha256
		},
		guest: {
			init_path: "/usr/local/lib/yeet-vm/yeet-init",
			init_sha256: $guest_init_sha256,
			agent_path: "/usr/local/lib/yeet-vm/yeet-agent",
			agent_sha256: $guest_agent_sha256
		},
		kernel_request: {
			release_id: $kernel_release,
			manifest_sha256: $kernel_manifest_sha256
		}
	}' >"$out_dir/provenance.json"

(
	cd "$out_dir"
	sha256sum rootfs.ext4.zst guest-manifest.json provenance.json >checksums.txt
)

rm -f "$out_dir/rootfs.ext4"

echo "Wrote NixOS guest base to $out_dir"
echo "Guest base: $guest_base_id"
echo "Default kernel request: $kernel_release"
