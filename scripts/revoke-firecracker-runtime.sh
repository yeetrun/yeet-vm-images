#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 --runtime-id ID --manifest-sha256 SHA256 --reason TEXT --recorded-at TIME --catalog-in FILE --catalog-out FILE" >&2; exit 2; }
fail() { echo "Firecracker runtime revocation failed: $*" >&2; exit 1; }
runtime_id="" manifest_sha256="" reason="" recorded_at="" catalog_in="" catalog_out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--runtime-id) [ "$#" -ge 2 ] || usage; runtime_id="$2"; shift 2 ;;
		--manifest-sha256) [ "$#" -ge 2 ] || usage; manifest_sha256="$2"; shift 2 ;;
		--reason) [ "$#" -ge 2 ] || usage; reason="$2"; shift 2 ;;
		--recorded-at) [ "$#" -ge 2 ] || usage; recorded_at="$2"; shift 2 ;;
		--catalog-in) [ "$#" -ge 2 ] || usage; catalog_in="$2"; shift 2 ;;
		--catalog-out) [ "$#" -ge 2 ] || usage; catalog_out="$2"; shift 2 ;;
		*) usage ;;
	esac
done
for required in runtime_id manifest_sha256 reason recorded_at catalog_in catalog_out; do [ -n "${!required}" ] || usage; done
[[ "$runtime_id" =~ ^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$ ]] || fail "invalid runtime ID"
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid manifest digest"
[ -n "${reason//[[:space:]]/}" ] || fail "revocation reason must not be blank"
jq -en --arg at "$recorded_at" '$at|fromdateiso8601' >/dev/null || fail "recorded-at must be an RFC 3339 UTC timestamp"
[ -f "$catalog_in" ] && [ ! -L "$catalog_in" ] || fail "input catalog is not a regular file"
[ ! -e "$catalog_out" ] || fail "output catalog already exists"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ] && command -v check-jsonschema >/dev/null 2>&1; then schema_validator="$(command -v check-jsonschema)"
elif [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || fail "missing required command: check-jsonschema"
"$repo_root/scripts/verify-runtime-catalog.sh" "$catalog_in"

count="$(jq --arg runtime "$runtime_id" '[.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)]|length' "$catalog_in")"
[ "$count" = 1 ] || fail "catalog must contain exactly one matching runtime ID"
jq -e --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" '
  .architectures.amd64.runtimes[]|select(.runtime_id==$runtime and .manifest_sha256==$manifest)
' "$catalog_in" >/dev/null || fail "runtime manifest digest does not match the catalog entry"

existing_revocations="$(jq --arg runtime "$runtime_id" '[.revocations[]|select(.runtime_id==$runtime)]|length' "$catalog_in")"
[ "$existing_revocations" -le 1 ] || fail "catalog contains duplicate revocations for runtime ID"
if [ "$existing_revocations" = 1 ]; then
	jq -e --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" --arg reason "$reason" --arg at "$recorded_at" '
      (.revocations[]|select(.runtime_id==$runtime))=={runtime_id:$runtime,manifest_sha256:$manifest,reason:$reason,recorded_at:$at} and
      (.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)).support=="revoked" and
      (.architectures.amd64.channels.stable==null or .architectures.amd64.channels.stable.runtime_id!=$runtime) and
      (.architectures.amd64.channels.candidate==null or .architectures.amd64.channels.candidate.runtime_id!=$runtime)
    ' "$catalog_in" >/dev/null || fail "runtime ID already has a conflicting revocation"
	cp "$catalog_in" "$catalog_out"
	exit 0
fi

out_parent="$(dirname "$catalog_out")"; [ -d "$out_parent" ] || fail "catalog output parent does not exist"
tmp_out="$(mktemp "$out_parent/.runtime-catalog.XXXXXX")"
cleanup() { rm -f "$tmp_out"; }
trap cleanup EXIT INT TERM
jq --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" --arg reason "$reason" --arg at "$recorded_at" '
  (.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)).support="revoked" |
  if .architectures.amd64.channels.stable.runtime_id?==$runtime then .architectures.amd64.channels.stable=null else . end |
  if .architectures.amd64.channels.candidate.runtime_id?==$runtime then .architectures.amd64.channels.candidate=null else . end |
  .revocations += [{runtime_id:$runtime,manifest_sha256:$manifest,reason:$reason,recorded_at:$at}]
' "$catalog_in" >"$tmp_out"
"$repo_root/scripts/verify-runtime-catalog.sh" "$tmp_out"
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-catalog.schema.json" "$tmp_out" >/dev/null || fail "revoked catalog is not schema-valid"
mv "$tmp_out" "$catalog_out"
trap - EXIT INT TERM
