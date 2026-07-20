#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
	echo "usage: $0 --runtime-release ID --runtime-manifest-sha256 SHA256 --ubuntu-guest-release ID --nixos-guest-release ID --current-kernel-release ID --previous-kernel-release ID --yeet-ref COMMIT --work-dir DIRECTORY --matrix-out FILE" >&2
	exit 2
}
fail() { echo "Firecracker runtime KVM integration failed: $*" >&2; exit 1; }
runtime_release="" runtime_manifest_sha256="" ubuntu_guest_release="" nixos_guest_release=""
current_kernel_release="" previous_kernel_release="" yeet_ref="" work_dir="" matrix_out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--runtime-release) [ "$#" -ge 2 ] || usage; runtime_release="$2"; shift 2 ;;
		--runtime-manifest-sha256) [ "$#" -ge 2 ] || usage; runtime_manifest_sha256="$2"; shift 2 ;;
		--ubuntu-guest-release) [ "$#" -ge 2 ] || usage; ubuntu_guest_release="$2"; shift 2 ;;
		--nixos-guest-release) [ "$#" -ge 2 ] || usage; nixos_guest_release="$2"; shift 2 ;;
		--current-kernel-release) [ "$#" -ge 2 ] || usage; current_kernel_release="$2"; shift 2 ;;
		--previous-kernel-release) [ "$#" -ge 2 ] || usage; previous_kernel_release="$2"; shift 2 ;;
		--yeet-ref) [ "$#" -ge 2 ] || usage; yeet_ref="$2"; shift 2 ;;
		--work-dir) [ "$#" -ge 2 ] || usage; work_dir="$2"; shift 2 ;;
		--matrix-out) [ "$#" -ge 2 ] || usage; matrix_out="$2"; shift 2 ;;
		*) usage ;;
	esac
done
for required in runtime_release runtime_manifest_sha256 ubuntu_guest_release nixos_guest_release current_kernel_release previous_kernel_release yeet_ref work_dir matrix_out; do
	[ -n "${!required}" ] || usage
done
[[ "$runtime_release" =~ ^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$ ]] || fail "invalid runtime release"
[[ "$runtime_manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid runtime manifest digest"
[[ "$ubuntu_guest_release" =~ ^ubuntu-[0-9]+[.][0-9]+-amd64-(kernel-[0-9]+[.][0-9]+([.][0-9]+)*-)?v[1-9][0-9]*$ ]] || fail "Ubuntu release must be an exact immutable ID"
[[ "$nixos_guest_release" =~ ^nixos-[0-9]+[.][0-9]+-amd64-(kernel-[0-9]+[.][0-9]+([.][0-9]+)*-)?v[1-9][0-9]*$ ]] || fail "NixOS release must be an exact immutable ID"
[[ "$current_kernel_release" =~ ^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$ ]] || fail "current kernel must be an exact immutable ID"
[[ "$previous_kernel_release" =~ ^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$ ]] || fail "previous kernel must be an exact immutable ID"
[[ "$yeet_ref" =~ ^[0-9a-f]{40}$ ]] || fail "Yeet ref must be an exact commit"
[ "$current_kernel_release" != "$previous_kernel_release" ] || fail "current and previous kernel releases must differ"
[ "$(cd "$(dirname "$matrix_out")" && pwd)/$(basename "$matrix_out")" != "$(cd "$(dirname "$work_dir")" && pwd)/$(basename "$work_dir")" ] || fail "matrix output must differ from work directory"
case "$(cd "$(dirname "$matrix_out")" && pwd)/$(basename "$matrix_out")" in
	"$(cd "$(dirname "$work_dir")" && pwd)/$(basename "$work_dir")"/*) fail "matrix output must be outside the disposable work directory" ;;
esac
[ ! -e "$work_dir" ] || fail "work directory already exists"
mkdir -p "$work_dir"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT INT TERM

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_mode="${YEET_RUNTIME_KVM_TEST_MODE:-0}"
if [ "$test_mode" != 1 ] && {
	[ -n "${YEET_KVM_VERIFY_RUNTIME:-}" ] || [ -n "${YEET_KVM_DOWNLOAD_RUNTIME:-}" ] ||
		[ -n "${YEET_KVM_DOWNLOAD_GUEST:-}" ] || [ -n "${YEET_KVM_DOWNLOAD_KERNEL:-}" ] ||
		[ -n "${YEET_KVM_CASE_RUNNER:-}" ];
}; then
	fail "integration helper overrides require explicit test mode"
fi
verify_runtime="${YEET_KVM_VERIFY_RUNTIME:-$repo_root/scripts/verify-published-firecracker-runtime.sh}"
download_runtime="${YEET_KVM_DOWNLOAD_RUNTIME:-$repo_root/scripts/download-published-firecracker-runtime.sh}"
download_guest="${YEET_KVM_DOWNLOAD_GUEST:-$repo_root/scripts/download-vm-image-release.sh}"
download_kernel="${YEET_KVM_DOWNLOAD_KERNEL:-$repo_root/scripts/download-published-kernel-release.sh}"
for helper in "$verify_runtime" "$download_runtime" "$download_guest" "$download_kernel"; do
	[ -x "$helper" ] || fail "required integration helper is not executable: $helper"
done

if [ "$test_mode" != 1 ]; then
	[ "$(uname -s)" = Linux ] || fail "KVM integration requires Linux"
	case "$(uname -m)" in x86_64|amd64) ;; *) fail "KVM integration requires amd64" ;; esac
	[ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] || fail "/dev/kvm is unavailable"
	privilege=()
	if [ "$(id -u)" -ne 0 ]; then
		if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true; then fail "root or passwordless sudo is required"; fi
		privilege=(sudo -n)
	fi
	command -v zfs >/dev/null 2>&1 || fail "ZFS tools are required"
	"${privilege[@]}" zfs list -H >/dev/null || fail "ZFS is not usable"
	test_user="${YEET_KVM_TEST_USER:-yeet-vm}"
	test_uid="$(id -u "$test_user" 2>/dev/null || true)"
	test_gid="$(id -g "$test_user" 2>/dev/null || true)"
	[ -n "$test_uid" ] && [ "$test_uid" -gt 0 ] && [ -n "$test_gid" ] && [ "$test_gid" -gt 0 ] || fail "dedicated non-root test identity is missing"
	yeet_source="${YEET_KVM_YEET_SOURCE_DIR:-}"
	[ -d "$yeet_source/.git" ] || fail "checked-out Yeet source is missing"
	[ "$(git -C "$yeet_source" rev-parse HEAD)" = "$yeet_ref" ] || fail "checked-out Yeet commit differs from --yeet-ref"
else
	test_user=yeet-vm test_uid=20001 test_gid=20001
	yeet_source="${YEET_KVM_YEET_SOURCE_DIR:-$work_dir/yeet-source}"
	mkdir -p "$yeet_source"
fi
case_runner="${YEET_KVM_CASE_RUNNER:-$yeet_source/scripts/test-firecracker-runtime-integration.sh}"
[ -x "$case_runner" ] || fail "the exact Yeet commit does not provide the repository-owned runtime integration driver: $case_runner"

runtime_dir="$work_dir/runtime"
ubuntu_dir="$work_dir/ubuntu"
nixos_dir="$work_dir/nixos"
current_kernel_dir="$work_dir/current-kernel"
previous_kernel_dir="$work_dir/previous-kernel"
"$verify_runtime" "$runtime_release" >/dev/null
"$download_runtime" "$runtime_release" "$runtime_manifest_sha256" "$runtime_dir"
"$download_guest" ubuntu "$ubuntu_guest_release" "$ubuntu_dir"
"$download_guest" nixos "$nixos_guest_release" "$nixos_dir"
"$download_kernel" "$current_kernel_release" "$current_kernel_dir"
"$download_kernel" "$previous_kernel_release" "$previous_kernel_dir"

if [ "$test_mode" != 1 ]; then
	version="$(jq -er '.upstream.version' "$runtime_dir/runtime-manifest.json")"
	[ "$("$runtime_dir/firecracker" --version | sed -n '1p')" = "Firecracker $version" ] || fail "Firecracker version probe mismatch"
	[ "$("$runtime_dir/jailer" --version | sed -n '1p')" = "Jailer $version" ] || fail "jailer version probe mismatch"
fi

shared_assertions=(api-ready boot natural-reboot network-ready disk-snapshot-restore cleanup jailer-uid-gid-drop no-memory-snapshot)
run_case() {
	local scenario="$1" guest="$2" kernel="$3" storage="$4" data_root="$5" service_root="$6"
	local args=(
		--scenario "$scenario" --launcher jailer-only
		--runtime-id "$runtime_release" --runtime-manifest-sha256 "$runtime_manifest_sha256"
		--firecracker "$runtime_dir/firecracker" --jailer "$runtime_dir/jailer"
		--guest-dir "$guest" --kernel "$kernel/vmlinux" --storage "$storage"
		--data-root "$data_root" --service-root "$service_root"
		--test-user "$test_user" --test-uid "$test_uid" --test-gid "$test_gid"
		--yeet-source "$yeet_source" --yeet-commit "$yeet_ref"
	)
	for assertion in "${shared_assertions[@]}"; do args+=(--assert "$assertion"); done
	if [ "$test_mode" = 1 ]; then
		"$case_runner" "${args[@]}"
	else
		"${privilege[@]}" "$case_runner" "${args[@]}"
	fi
}

run_case ubuntu-current "$ubuntu_dir" "$current_kernel_dir" raw "$work_dir/data-default" "$work_dir/service-ubuntu"
run_case nixos-current "$nixos_dir" "$current_kernel_dir" raw "$work_dir/data-default" "$work_dir/service-nixos"
run_case previous-kernel "$ubuntu_dir" "$previous_kernel_dir" raw "$work_dir/data-default" "$work_dir/service-previous"
run_case raw-storage "$ubuntu_dir" "$current_kernel_dir" raw "$work_dir/data-raw" "$work_dir/service-raw"
run_case zfs-storage "$ubuntu_dir" "$current_kernel_dir" zfs "$work_dir/data-zfs" "$work_dir/service-zfs"
run_case custom-roots "$nixos_dir" "$current_kernel_dir" raw "$work_dir/custom-data" "$work_dir/custom-services/vm"
run_case jailer-drop "$ubuntu_dir" "$current_kernel_dir" raw "$work_dir/data-drop" "$work_dir/service-drop"

matrix_parent="$(dirname "$matrix_out")"
[ -d "$matrix_parent" ] || fail "matrix output parent does not exist"
tmp_matrix="$(mktemp "$matrix_parent/.runtime-matrix.XXXXXX")"
jq -n '{ubuntu:"passed",nixos:"passed",current_kernel:"passed",previous_kernel:"passed",raw:"passed",zfs:"passed",custom_roots:"passed",jailer_drop:"passed"}' >"$tmp_matrix"
mv "$tmp_matrix" "$matrix_out"
trap - EXIT INT TERM
rm -rf "$work_dir"
