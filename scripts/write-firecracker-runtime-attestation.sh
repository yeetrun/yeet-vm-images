#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
	echo "usage: $0 --runtime-id ID --manifest-sha256 SHA256 --source-commit COMMIT --workflow-run RUN_ID --yeet-commit COMMIT --ubuntu-guest-release RELEASE --nixos-guest-release RELEASE --current-kernel-release RELEASE --previous-kernel-release RELEASE --matrix-file FILE --started-at TIME --completed-at TIME --out FILE" >&2
	exit 2
}
fail() { echo "Firecracker runtime attestation write failed: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$repo_root/schemas/firecracker-runtime-attestation.schema.json"
runtime_id="" manifest_sha256="" source_commit="" workflow_run="" yeet_commit=""
ubuntu_guest_release="" nixos_guest_release="" current_kernel_release="" previous_kernel_release=""
matrix_file="" started_at="" completed_at="" out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--runtime-id) [ "$#" -ge 2 ] || usage; runtime_id="$2"; shift 2 ;;
		--manifest-sha256) [ "$#" -ge 2 ] || usage; manifest_sha256="$2"; shift 2 ;;
		--source-commit) [ "$#" -ge 2 ] || usage; source_commit="$2"; shift 2 ;;
		--workflow-run) [ "$#" -ge 2 ] || usage; workflow_run="$2"; shift 2 ;;
		--yeet-commit) [ "$#" -ge 2 ] || usage; yeet_commit="$2"; shift 2 ;;
		--ubuntu-guest-release) [ "$#" -ge 2 ] || usage; ubuntu_guest_release="$2"; shift 2 ;;
		--nixos-guest-release) [ "$#" -ge 2 ] || usage; nixos_guest_release="$2"; shift 2 ;;
		--current-kernel-release) [ "$#" -ge 2 ] || usage; current_kernel_release="$2"; shift 2 ;;
		--previous-kernel-release) [ "$#" -ge 2 ] || usage; previous_kernel_release="$2"; shift 2 ;;
		--matrix-file) [ "$#" -ge 2 ] || usage; matrix_file="$2"; shift 2 ;;
		--started-at) [ "$#" -ge 2 ] || usage; started_at="$2"; shift 2 ;;
		--completed-at) [ "$#" -ge 2 ] || usage; completed_at="$2"; shift 2 ;;
		--out) [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
		*) usage ;;
	esac
done

for required in runtime_id manifest_sha256 source_commit workflow_run yeet_commit ubuntu_guest_release nixos_guest_release current_kernel_release previous_kernel_release matrix_file started_at completed_at out; do
	[ -n "${!required}" ] || usage
done
[ -f "$matrix_file" ] && [ ! -L "$matrix_file" ] || fail "matrix evidence is not a regular file"
command -v jq >/dev/null 2>&1 || fail "missing required command: jq"
jq -en --arg started "$started_at" --arg completed "$completed_at" '
  ($started | fromdateiso8601) <= ($completed | fromdateiso8601)
' >/dev/null || fail "timestamps are invalid or completion precedes start time"

schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ] && command -v check-jsonschema >/dev/null 2>&1; then schema_validator="$(command -v check-jsonschema)"
elif [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || fail "missing required command: check-jsonschema"

out_parent="$(dirname "$out")"
[ -d "$out_parent" ] || fail "output parent does not exist"
tmp_out="$(mktemp "$out_parent/.runtime-attestation.XXXXXX")"
cleanup() { rm -f "$tmp_out"; }
trap cleanup EXIT INT TERM

jq -n \
	--arg runtime_id "$runtime_id" --arg manifest_sha256 "$manifest_sha256" \
	--arg source_commit "$source_commit" --arg workflow_run "$workflow_run" --arg yeet_commit "$yeet_commit" \
	--arg ubuntu "$ubuntu_guest_release" --arg nixos "$nixos_guest_release" \
	--arg current "$current_kernel_release" --arg previous "$previous_kernel_release" \
	--slurpfile matrix "$matrix_file" --arg started_at "$started_at" --arg completed_at "$completed_at" '
  {
    schema_version: 1,
    kind: "integration",
    subject: {runtime_id: $runtime_id, manifest_sha256: $manifest_sha256},
    runner: {class: "self-hosted-linux-kvm", architecture: "amd64"},
    source: {repository: "yeetrun/yeet-vm-images", commit: $source_commit, workflow_run: $workflow_run},
    tested_yeet: {repository: "yeetrun/yeet", commit: $yeet_commit},
    artifacts: {
      ubuntu_guest_release: $ubuntu,
      nixos_guest_release: $nixos,
      current_kernel_release: $current,
      previous_kernel_release: $previous
    },
    matrix: $matrix[0],
    started_at: $started_at,
    completed_at: $completed_at,
    result: "passed"
  }
' >"$tmp_out"
"$schema_validator" --schemafile "$schema" "$tmp_out" >/dev/null || fail "generated attestation is not schema-valid"
mv "$tmp_out" "$out"
trap - EXIT INT TERM
