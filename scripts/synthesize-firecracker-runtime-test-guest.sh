#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 --guest-dir DIR --kernel-dir DIR --runtime-dir DIR --out-dir DIR" >&2; exit 2; }
fail() { echo "Firecracker runtime test-guest synthesis failed: $*" >&2; exit 1; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
regular_file() { [ -f "$1" ] && [ ! -L "$1" ] || fail "$2 must be a regular file, not a symbolic link"; }

guest_dir="" kernel_dir="" runtime_dir="" out_dir=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--guest-dir) [ "$#" -ge 2 ] || usage; guest_dir="$2"; shift 2 ;;
		--kernel-dir) [ "$#" -ge 2 ] || usage; kernel_dir="$2"; shift 2 ;;
		--runtime-dir) [ "$#" -ge 2 ] || usage; runtime_dir="$2"; shift 2 ;;
		--out-dir) [ "$#" -ge 2 ] || usage; out_dir="$2"; shift 2 ;;
		*) usage ;;
	esac
done
for required in guest_dir kernel_dir runtime_dir out_dir; do [ -n "${!required}" ] || usage; done
for cmd in cp jq mkdir mktemp mv sha256sum; do command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd"; done
for dir in "$guest_dir" "$kernel_dir" "$runtime_dir"; do [ -d "$dir" ] && [ ! -L "$dir" ] || fail "component directory is missing or symbolic: $dir"; done
[ ! -e "$out_dir" ] || fail "output path already exists"

guest_manifest="$guest_dir/guest-manifest.json"
guest_rootfs="$guest_dir/rootfs.ext4.zst"
kernel_manifest="$kernel_dir/kernel-manifest.json"
kernel="$kernel_dir/vmlinux"
runtime_manifest="$runtime_dir/runtime-manifest.json"
firecracker="$runtime_dir/firecracker"
jailer="$runtime_dir/jailer"
regular_file "$guest_manifest" "guest manifest"
regular_file "$guest_rootfs" "guest rootfs"
regular_file "$kernel_manifest" "kernel manifest"
regular_file "$kernel" "kernel"
regular_file "$runtime_manifest" "runtime manifest"
regular_file "$firecracker" "Firecracker"
regular_file "$jailer" "jailer"

guest_identity="$(jq -cer '
  select(.schema_version == 1 and (.guest_base_id | test("^guest-(ubuntu|nixos)-[0-9]+[.][0-9]+-amd64-v[1-9][0-9]*$")) and
    (.os == "ubuntu" or .os == "nixos") and (.os_version | test("^[0-9]+[.][0-9]+$")) and .architecture == "amd64" and
    .guest_base_id == ("guest-" + .os + "-" + .os_version + "-amd64-" + (.guest_base_id | capture("-(?<revision>v[1-9][0-9]*)$").revision)) and
    (.rootfs.sha256 | test("^[0-9a-f]{64}$")) and (.rootfs.uncompressed_bytes | type == "number" and . > 0 and floor == .)) |
  {id:.guest_base_id,os,version:.os_version,rootfs_sha256:.rootfs.sha256,rootfs_size:.rootfs.uncompressed_bytes}
' "$guest_manifest")" || fail "guest manifest identity or lifecycle contract mismatch"
kernel_identity="$(jq -cer '
  select(.schema_version == 1 and (.kernel_id | test("^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$")) and
    (.upstream_version | test("^[0-9]+[.][0-9]+([.][0-9]+)*$")) and .architecture == "amd64" and
    (.vmlinux.sha256 | test("^[0-9a-f]{64}$"))) |
  {id:.kernel_id,version:.upstream_version,kernel_sha256:.vmlinux.sha256}
' "$kernel_manifest")" || fail "kernel manifest identity or lifecycle contract mismatch"
runtime_identity="$(jq -cer '
  select(.schema_version == 1 and (.runtime_id | test("^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$")) and
    .architecture == "amd64" and .components.firecracker.path == "firecracker" and .components.jailer.path == "jailer" and
    (.components.firecracker.sha256 | test("^[0-9a-f]{64}$")) and (.components.jailer.sha256 | test("^[0-9a-f]{64}$"))) |
  {id:.runtime_id,firecracker_sha256:.components.firecracker.sha256,jailer_sha256:.components.jailer.sha256}
' "$runtime_manifest")" || fail "runtime manifest identity or lifecycle contract mismatch"

rootfs_sha="$(sha256_file "$guest_rootfs")"
kernel_sha="$(sha256_file "$kernel")"
firecracker_sha="$(sha256_file "$firecracker")"
jailer_sha="$(sha256_file "$jailer")"
[ "$rootfs_sha" = "$(jq -er '.rootfs_sha256' <<<"$guest_identity")" ] || fail "guest rootfs digest mismatch"
[ "$kernel_sha" = "$(jq -er '.kernel_sha256' <<<"$kernel_identity")" ] || fail "kernel digest mismatch"
[ "$firecracker_sha" = "$(jq -er '.firecracker_sha256' <<<"$runtime_identity")" ] || fail "Firecracker digest mismatch"
[ "$jailer_sha" = "$(jq -er '.jailer_sha256' <<<"$runtime_identity")" ] || fail "jailer digest mismatch"

guest_id="$(jq -er '.id' <<<"$guest_identity")"
guest_os="$(jq -er '.os' <<<"$guest_identity")"
os_version="$(jq -er '.version' <<<"$guest_identity")"
rootfs_size="$(jq -er '.rootfs_size' <<<"$guest_identity")"
kernel_id="$(jq -er '.id' <<<"$kernel_identity")"
kernel_version="$(jq -er '.version' <<<"$kernel_identity")"
runtime_id="$(jq -er '.id' <<<"$runtime_identity")"
version="$guest_id--$kernel_id--$runtime_id"
case "$guest_os" in
	ubuntu) default_user=ubuntu; guest_system_init="" ;;
	nixos) default_user=nixos; guest_system_init=/run/current-system/init ;;
	*) fail "unsupported guest OS: $guest_os" ;;
esac

parent="$(dirname "$out_dir")"
mkdir -p "$parent"
staging="$(mktemp -d "$parent/.runtime-test-guest.XXXXXX")"
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT INT TERM
cp "$guest_rootfs" "$staging/rootfs.ext4.zst"
cp "$kernel" "$staging/vmlinux"
cp "$firecracker" "$staging/firecracker"
cp "$jailer" "$staging/jailer"
chmod 0644 "$staging/rootfs.ext4.zst" "$staging/vmlinux"
chmod 0755 "$staging/firecracker" "$staging/jailer"
jq -n \
	--arg name "yeet-$guest_os-$os_version" --arg version "$version" \
	--arg os "$guest_os" --arg os_version "$os_version" --arg default_user "$default_user" \
	--arg guest_system_init "$guest_system_init" --arg kernel_id "$kernel_id" --arg kernel_version "$kernel_version" \
	--argjson rootfs_size "$rootfs_size" --arg rootfs_sha "$rootfs_sha" --arg kernel_sha "$kernel_sha" \
	--arg firecracker_sha "$firecracker_sha" --arg jailer_sha "$jailer_sha" '
  {
    name:$name,version:$version,architecture:"amd64",image_profile:($os+"-"+$os_version),
    distro:$os,distro_version:$os_version,default_user:$default_user,kernel_policy:"yeet-managed",
    guest_init:"/usr/local/lib/yeet-vm/yeet-init",guest_system_init:$guest_system_init,
    metadata_driver:$os,snap_support:false,kernel:"vmlinux",rootfs:"rootfs.ext4.zst",
    firecracker:"firecracker",jailer:"jailer",rootfs_size:$rootfs_size,
    kernel_version:$kernel_id,upstream_kernel_version:$kernel_version,
    checksums:{"rootfs.ext4.zst":$rootfs_sha,vmlinux:$kernel_sha,firecracker:$firecracker_sha,jailer:$jailer_sha}
  } | if .guest_system_init == "" then del(.guest_system_init) else . end
' >"$staging/manifest.json"
chmod 0644 "$staging/manifest.json"
mv "$staging" "$out_dir"
trap - EXIT INT TERM
