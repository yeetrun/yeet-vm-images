#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 <kernel-release> <out-dir>" >&2
	exit 2
}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

if [ "$#" -ne 2 ]; then
	usage
fi

kernel_release="$1"
out_dir="$2"
repo="${GITHUB_REPOSITORY:-yeetrun/yeet-vm-images}"
expected_kernel_version="${YEET_KERNEL_VERSION:-}"
expected_source_url="${YEET_KERNEL_SOURCE_URL:-}"
expected_source_sha256="${YEET_KERNEL_SOURCE_SHA256:-}"
expected_config_url="${YEET_KERNEL_CONFIG_URL:-}"
expected_build_fingerprint="${YEET_KERNEL_BUILD_FINGERPRINT:-}"

for cmd in awk curl jq mkdir sha256sum; do
	require "$cmd"
done

if [[ ! "$kernel_release" =~ ^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[0-9]+$ ]]; then
	echo "invalid kernel release: $kernel_release" >&2
	exit 1
fi

mkdir -p "$out_dir"
asset_base="https://github.com/${repo}/releases/download/${kernel_release}"
curl -fsSL --retry 3 -o "$out_dir/kernel-manifest.json" "$asset_base/kernel-manifest.json"
curl -fsSL --retry 3 -o "$out_dir/vmlinux" "$asset_base/vmlinux"
curl -fsSL --retry 3 -o "$out_dir/kernel.config" "$asset_base/kernel.config"

manifest_release="$(jq -r '.release' "$out_dir/kernel-manifest.json")"
if [ "$manifest_release" != "$kernel_release" ]; then
	echo "kernel manifest release mismatch: manifest=$manifest_release requested=$kernel_release" >&2
	exit 1
fi

if [ -n "$expected_kernel_version" ]; then
	manifest_upstream="$(jq -r '.upstream_kernel_version' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_upstream" != "$expected_kernel_version" ]; then
		echo "kernel manifest version mismatch: manifest=$manifest_upstream expected=$expected_kernel_version" >&2
		exit 1
	fi
fi

if [ -n "$expected_source_url" ]; then
	manifest_source_url="$(jq -r '.kernel_source_url' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_source_url" != "$expected_source_url" ]; then
		echo "kernel source URL mismatch: manifest=$manifest_source_url expected=$expected_source_url" >&2
		exit 1
	fi
fi

if [ -n "$expected_source_sha256" ]; then
	manifest_source_sha256="$(jq -r '.kernel_source_sha256' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_source_sha256" != "$expected_source_sha256" ]; then
		echo "kernel source SHA mismatch: manifest=$manifest_source_sha256 expected=$expected_source_sha256" >&2
		exit 1
	fi
fi

if [ -n "$expected_config_url" ]; then
	manifest_config_url="$(jq -r '.kernel_config_url' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_config_url" != "$expected_config_url" ]; then
		echo "kernel config URL mismatch: manifest=$manifest_config_url expected=$expected_config_url" >&2
		exit 1
	fi
fi

if [ -n "$expected_build_fingerprint" ]; then
	manifest_build_fingerprint="$(jq -r '.kernel_build_fingerprint // empty' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_build_fingerprint" != "$expected_build_fingerprint" ]; then
		echo "kernel build fingerprint mismatch: manifest=${manifest_build_fingerprint:-missing} expected=$expected_build_fingerprint" >&2
		exit 1
	fi
fi

check_asset() {
	local asset="$1"
	local want
	local got
	want="$(jq -r --arg asset "$asset" '.checksums[$asset] // empty' "$out_dir/kernel-manifest.json")"
	if [ -z "$want" ]; then
		echo "kernel manifest missing checksum for $asset" >&2
		exit 1
	fi
	got="$(sha256sum "$out_dir/$asset" | awk '{ print $1 }')"
	if [ "$got" != "$want" ]; then
		echo "$asset checksum mismatch: got $got, want $want" >&2
		exit 1
	fi
}

check_asset vmlinux
check_asset kernel.config
(
	cd "$out_dir"
	sha256sum vmlinux kernel.config >kernel-checksums.txt
)
