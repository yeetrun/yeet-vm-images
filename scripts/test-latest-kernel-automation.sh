#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
script_dir="${script_source%/*}"
if [ "$script_dir" = "$script_source" ]; then
	script_dir="."
fi
script_dir="$(cd "$script_dir" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
testdata_dir="$repo_root/scripts/testdata"

kernel_info="$(
	YEET_KERNEL_RELEASES_JSON_URL="file://$testdata_dir/kernel-releases-7.1.1.json" \
	YEET_KERNEL_SHA256SUMS_URL="file://$testdata_dir/kernel-sha256sums-7.x.asc" \
		"$repo_root/scripts/resolve-latest-kernel.sh"
)"

jq -e '
  .moniker == "stable" and
  .version == "7.1.1" and
  .source_url == "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz" and
  .source_sha256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" and
  .released == "2026-06-19"
' <<<"$kernel_info" >/dev/null

ubuntu_version="$("$repo_root/scripts/next-image-version.sh" ubuntu-26.04-amd64 7.1.2 "$testdata_dir/image-release-tags.txt")"
jq -e '
  .family == "ubuntu-26.04-amd64" and
  .upstream_kernel_version == "7.1.2" and
  .image_revision == 17 and
  .version == "ubuntu-26.04-amd64-kernel-7.1.2-v17"
' <<<"$ubuntu_version" >/dev/null

nixos_version="$("$repo_root/scripts/next-image-version.sh" nixos-26.05-amd64 7.1.2 "$testdata_dir/image-release-tags.txt")"
jq -e '
  .family == "nixos-26.05-amd64" and
  .upstream_kernel_version == "7.1.2" and
  .image_revision == 16 and
  .version == "nixos-26.05-amd64-kernel-7.1.2-v16"
' <<<"$nixos_version" >/dev/null
