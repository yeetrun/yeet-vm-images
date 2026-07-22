#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
	echo "usage: $0 --runtime-release ID --runtime-manifest-sha256 SHA256 --ubuntu-guest-release ID --nixos-guest-release ID --current-kernel-release ID --previous-kernel-release ID --yeet-ref COMMIT --work-dir DIRECTORY --evidence-out FILE" >&2
	exit 2
}
fail() { echo "Firecracker runtime canary failed: $*" >&2; exit 1; }
runtime_release="" runtime_manifest_sha256="" ubuntu_guest_release="" nixos_guest_release=""
current_kernel_release="" previous_kernel_release="" yeet_ref="" work_dir="" evidence_out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--runtime-release) runtime_release="$2"; shift 2 ;;
		--runtime-manifest-sha256) runtime_manifest_sha256="$2"; shift 2 ;;
		--ubuntu-guest-release) ubuntu_guest_release="$2"; shift 2 ;;
		--nixos-guest-release) nixos_guest_release="$2"; shift 2 ;;
		--current-kernel-release) current_kernel_release="$2"; shift 2 ;;
		--previous-kernel-release) previous_kernel_release="$2"; shift 2 ;;
		--yeet-ref) yeet_ref="$2"; shift 2 ;;
		--work-dir) work_dir="$2"; shift 2 ;;
		--evidence-out) evidence_out="$2"; shift 2 ;;
		*) usage ;;
	esac
done
for required in runtime_release runtime_manifest_sha256 ubuntu_guest_release nixos_guest_release current_kernel_release previous_kernel_release yeet_ref work_dir evidence_out; do [ -n "${!required}" ] || usage; done
[ ! -e "$work_dir" ] || fail "work directory already exists"
evidence_parent="$(dirname "$evidence_out")"; [ -d "$evidence_parent" ] || fail "evidence output parent does not exist"
evidence_abs="$(cd "$evidence_parent" && pwd)/$(basename "$evidence_out")"
work_parent="$(dirname "$work_dir")"; [ -d "$work_parent" ] || fail "work directory parent does not exist"
work_abs="$(cd "$work_parent" && pwd)/$(basename "$work_dir")"
case "$evidence_abs" in "$work_abs"|"$work_abs"/*) fail "evidence output must be outside the disposable work directory" ;; esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${YEET_CANARY_KVM_HARNESS:-$repo_root/scripts/test-firecracker-runtime-kvm.sh}"
if [ "$harness" != "$repo_root/scripts/test-firecracker-runtime-kvm.sh" ] && [ "${YEET_RUNTIME_CANARY_TEST_MODE:-}" != 1 ]; then
	fail "canary harness override requires explicit test mode"
fi
[ -x "$harness" ] || fail "KVM harness is unavailable"
mkdir "$work_dir"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT INT TERM

for cycle in 1 2 3 4 5; do
	matrix="$work_dir/matrix-$cycle.json"
	"$harness" \
		--runtime-release "$runtime_release" --runtime-manifest-sha256 "$runtime_manifest_sha256" \
		--ubuntu-guest-release "$ubuntu_guest_release" --nixos-guest-release "$nixos_guest_release" \
		--current-kernel-release "$current_kernel_release" --previous-kernel-release "$previous_kernel_release" \
		--yeet-ref "$yeet_ref" --work-dir "$work_dir/cycle-$cycle" --matrix-out "$matrix"
	jq -e 'keys==["current_kernel","custom_roots","jailer_drop","nixos","previous_kernel","raw","ubuntu","zfs"] and all(.[];.=="passed")' "$matrix" >/dev/null || fail "cycle $cycle matrix is incomplete"
	if [ "$cycle" -gt 1 ]; then cmp -s "$work_dir/matrix-1.json" "$matrix" || fail "canary matrices differ across cycles"; fi
done

tmp_out="$(mktemp "$evidence_parent/.runtime-canary-evidence.XXXXXX")"
jq -n --slurpfile matrix "$work_dir/matrix-1.json" '{
  matrix:$matrix[0],
  boot_cycles:180,
  natural_reboots:35,
  disk_restore_cycles:5,
  functional_cycles:5
}' >"$tmp_out"
mv "$tmp_out" "$evidence_out"
rm -rf "$work_dir"
trap - EXIT INT TERM
