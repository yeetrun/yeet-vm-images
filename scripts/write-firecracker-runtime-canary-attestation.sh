#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
	echo "usage: $0 --runtime-id ID --manifest-sha256 SHA256 --source-commit COMMIT --workflow-run RUN_ID --yeet-commit COMMIT --ubuntu-guest-release ID --nixos-guest-release ID --current-kernel-release ID --previous-kernel-release ID --matrix-file FILE --boot-cycles N --natural-reboots N --disk-restore-cycles N --soak-seconds N --emergency-override true|false [--emergency-approver NAME --emergency-reason TEXT] --started-at TIME --completed-at TIME --out FILE" >&2
	exit 2
}
fail() { echo "Firecracker runtime canary attestation write failed: $*" >&2; exit 1; }

runtime_id="" manifest_sha256="" source_commit="" workflow_run="" yeet_commit=""
ubuntu_guest_release="" nixos_guest_release="" current_kernel_release="" previous_kernel_release=""
matrix_file="" boot_cycles="" natural_reboots="" disk_restore_cycles="" soak_seconds=""
emergency_override="" emergency_approver="" emergency_reason="" started_at="" completed_at="" out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--runtime-id) runtime_id="$2"; shift 2 ;;
		--manifest-sha256) manifest_sha256="$2"; shift 2 ;;
		--source-commit) source_commit="$2"; shift 2 ;;
		--workflow-run) workflow_run="$2"; shift 2 ;;
		--yeet-commit) yeet_commit="$2"; shift 2 ;;
		--ubuntu-guest-release) ubuntu_guest_release="$2"; shift 2 ;;
		--nixos-guest-release) nixos_guest_release="$2"; shift 2 ;;
		--current-kernel-release) current_kernel_release="$2"; shift 2 ;;
		--previous-kernel-release) previous_kernel_release="$2"; shift 2 ;;
		--matrix-file) matrix_file="$2"; shift 2 ;;
		--boot-cycles) boot_cycles="$2"; shift 2 ;;
		--natural-reboots) natural_reboots="$2"; shift 2 ;;
		--disk-restore-cycles) disk_restore_cycles="$2"; shift 2 ;;
		--soak-seconds) soak_seconds="$2"; shift 2 ;;
		--emergency-override) emergency_override="$2"; shift 2 ;;
		--emergency-approver) emergency_approver="$2"; shift 2 ;;
		--emergency-reason) emergency_reason="$2"; shift 2 ;;
		--started-at) started_at="$2"; shift 2 ;;
		--completed-at) completed_at="$2"; shift 2 ;;
		--out) out="$2"; shift 2 ;;
		*) usage ;;
	esac
done
for required in runtime_id manifest_sha256 source_commit workflow_run yeet_commit ubuntu_guest_release nixos_guest_release current_kernel_release previous_kernel_release matrix_file boot_cycles natural_reboots disk_restore_cycles soak_seconds emergency_override started_at completed_at out; do
	[ -n "${!required}" ] || usage
done
case "$emergency_override" in
	true) [ -n "${emergency_approver//[[:space:]]/}" ] && [ -n "${emergency_reason//[[:space:]]/}" ] || fail "emergency override requires approver and reason" ;;
	false) [ -z "$emergency_approver" ] && [ -z "$emergency_reason" ] || fail "ordinary canary must not record emergency metadata" ;;
	*) fail "emergency override must be true or false" ;;
esac
for counter in boot_cycles natural_reboots disk_restore_cycles soak_seconds; do [[ "${!counter}" =~ ^[0-9]+$ ]] || fail "$counter must be a non-negative integer"; done
[ -f "$matrix_file" ] && [ ! -L "$matrix_file" ] || fail "matrix evidence is not a regular file"
jq -en --arg started "$started_at" --arg completed "$completed_at" '($started|fromdateiso8601) <= ($completed|fromdateiso8601)' >/dev/null || fail "timestamps are invalid or reversed"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ] && command -v check-jsonschema >/dev/null 2>&1; then schema_validator="$(command -v check-jsonschema)"
elif [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || fail "missing required command: check-jsonschema"
out_parent="$(dirname "$out")"; [ -d "$out_parent" ] || fail "output parent does not exist"
tmp_out="$(mktemp "$out_parent/.runtime-canary-attestation.XXXXXX")"
cleanup() { rm -f "$tmp_out"; }
trap cleanup EXIT INT TERM

jq -n \
	--arg runtime "$runtime_id" --arg manifest "$manifest_sha256" --arg source "$source_commit" --arg run "$workflow_run" --arg yeet "$yeet_commit" \
	--arg ubuntu "$ubuntu_guest_release" --arg nixos "$nixos_guest_release" --arg current "$current_kernel_release" --arg previous "$previous_kernel_release" \
	--slurpfile matrix "$matrix_file" --argjson boots "$boot_cycles" --argjson reboots "$natural_reboots" --argjson restores "$disk_restore_cycles" \
	--argjson soak "$soak_seconds" --argjson emergency "$emergency_override" --arg approver "$emergency_approver" --arg reason "$emergency_reason" \
	--arg started "$started_at" --arg completed "$completed_at" '
  {
    schema_version:1,kind:"canary",
    subject:{runtime_id:$runtime,manifest_sha256:$manifest},
    runner:{class:"self-hosted-linux-kvm",architecture:"amd64"},
    source:{repository:"yeetrun/yeet-vm-images",commit:$source,workflow_run:$run},
    tested_yeet:{repository:"yeetrun/yeet",commit:$yeet},
    artifacts:{ubuntu_guest_release:$ubuntu,nixos_guest_release:$nixos,current_kernel_release:$current,previous_kernel_release:$previous},
    matrix:$matrix[0],
    canary:{
      boot_cycles:$boots,natural_reboots:$reboots,disk_restore_cycles:$restores,soak_seconds:$soak,
      runtime_upgrade:"passed",runtime_trial:"passed",runtime_fallback:"passed",runtime_rollback:"passed",
      kernel_sync_current:"passed",kernel_sync_previous:"passed",networking:"passed",catch_restart:"passed",
      interrupted_transaction_recovery:"passed",emergency_override:$emergency,
      emergency_approver:(if $emergency then $approver else null end),
      emergency_reason:(if $emergency then $reason else null end)
    },
    started_at:$started,completed_at:$completed,result:"passed"
  }
' >"$tmp_out"
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-attestation.schema.json" "$tmp_out" >/dev/null || fail "generated canary attestation is not schema-valid"
mv "$tmp_out" "$out"
trap - EXIT INT TERM
