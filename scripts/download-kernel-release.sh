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
expected_manifest_sha256="${YEET_KERNEL_MANIFEST_SHA256:-}"

for cmd in awk curl jq mkdir sha256sum; do
	require "$cmd"
done

if [[ ! "$kernel_release" =~ ^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$ ]]; then
	echo "invalid kernel release: $kernel_release" >&2
	exit 1
fi

mkdir -p "$out_dir"
asset_base="https://github.com/${repo}/releases/download/${kernel_release}"
curl -fsSL --retry 3 -o "$out_dir/kernel-manifest.json" "$asset_base/kernel-manifest.json"
manifest_sha256="$(sha256sum "$out_dir/kernel-manifest.json" | awk '{ print $1 }')"
if [ -n "$expected_manifest_sha256" ] && [ "$manifest_sha256" != "$expected_manifest_sha256" ]; then
	echo "kernel manifest SHA-256 mismatch: manifest=$manifest_sha256 expected=$expected_manifest_sha256" >&2
	exit 1
fi

jq -e --arg release "$kernel_release" '
	def sha256: type == "string" and test("^[0-9a-f]{64}$");
	keys == ["architecture", "config", "guest_packages", "kernel_id", "packaging_revision", "provenance", "schema_version", "upstream_version", "vmlinux"] and
	.schema_version == 1 and
	.kernel_id == $release and
	.kernel_id == "kernel-linux-\(.upstream_version)-yeet-v\(.packaging_revision)" and
	.architecture == "amd64" and
	.vmlinux.url == "https://github.com/yeetrun/yeet-vm-images/releases/download/\($release)/vmlinux" and
	(.vmlinux.sha256 | sha256) and
	.config.url == "https://github.com/yeetrun/yeet-vm-images/releases/download/\($release)/kernel.config" and
	(.config.sha256 | sha256) and
	.guest_packages == {
		catalog_url: "https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-packages/catalog.json",
		selector_schema_version: 2,
		release_id: $release
	} and
	(.provenance.source_commit | type == "string" and test("^[0-9a-f]{40}$")) and
	(.provenance.workflow_run_url | type == "string" and test("^https://github[.]com/yeetrun/yeet-vm-images/actions/runs/[1-9][0-9]*$"))
' "$out_dir/kernel-manifest.json" >/dev/null || { echo "invalid kernel manifest contract" >&2; exit 1; }

curl -fsSL --retry 3 -o "$out_dir/vmlinux" "$asset_base/vmlinux"
curl -fsSL --retry 3 -o "$out_dir/kernel.config" "$asset_base/kernel.config"

manifest_release="$(jq -r '.kernel_id' "$out_dir/kernel-manifest.json")"
if [ "$manifest_release" != "$kernel_release" ]; then
	echo "kernel manifest release mismatch: manifest=$manifest_release requested=$kernel_release" >&2
	exit 1
fi

if [ -n "$expected_kernel_version" ]; then
	manifest_upstream="$(jq -r '.upstream_version' "$out_dir/kernel-manifest.json")"
	if [ "$manifest_upstream" != "$expected_kernel_version" ]; then
		echo "kernel manifest version mismatch: manifest=$manifest_upstream expected=$expected_kernel_version" >&2
		exit 1
	fi
fi

check_asset() {
	local asset="$1"
	local want
	local got
	case "$asset" in
		vmlinux) want="$(jq -r '.vmlinux.sha256' "$out_dir/kernel-manifest.json")" ;;
		kernel.config) want="$(jq -r '.config.sha256' "$out_dir/kernel-manifest.json")" ;;
		*) echo "unsupported kernel asset: $asset" >&2; exit 1 ;;
	esac
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
