#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
	echo "usage: $0 --channel <candidate|stable> --runtime-id ID --manifest-sha256 SHA256 --integration-attestation-url URL --integration-attestation-sha256 SHA256 [--canary-attestation-url URL --canary-attestation-sha256 SHA256] --catalog-in FILE --catalog-out FILE" >&2
	exit 2
}
fail() { echo "Firecracker runtime promotion failed: $*" >&2; exit 1; }

channel="" runtime_id="" manifest_sha256=""
integration_url="" integration_sha="" canary_url="" canary_sha=""
catalog_in="" catalog_out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--channel) [ "$#" -ge 2 ] || usage; channel="$2"; shift 2 ;;
		--runtime-id) [ "$#" -ge 2 ] || usage; runtime_id="$2"; shift 2 ;;
		--manifest-sha256) [ "$#" -ge 2 ] || usage; manifest_sha256="$2"; shift 2 ;;
		--integration-attestation-url) [ "$#" -ge 2 ] || usage; integration_url="$2"; shift 2 ;;
		--integration-attestation-sha256) [ "$#" -ge 2 ] || usage; integration_sha="$2"; shift 2 ;;
		--canary-attestation-url) [ "$#" -ge 2 ] || usage; canary_url="$2"; shift 2 ;;
		--canary-attestation-sha256) [ "$#" -ge 2 ] || usage; canary_sha="$2"; shift 2 ;;
		--catalog-in) [ "$#" -ge 2 ] || usage; catalog_in="$2"; shift 2 ;;
		--catalog-out) [ "$#" -ge 2 ] || usage; catalog_out="$2"; shift 2 ;;
		*) usage ;;
	esac
done
for required in channel runtime_id manifest_sha256 integration_url integration_sha catalog_in catalog_out; do
	[ -n "${!required}" ] || usage
done
case "$channel" in
	candidate) [ -z "$canary_url" ] && [ -z "$canary_sha" ] || fail "candidate promotion does not accept canary evidence" ;;
	stable) [ -n "$canary_url" ] && [ -n "$canary_sha" ] || usage ;;
	*) fail "channel must be candidate or stable" ;;
esac
[[ "$runtime_id" =~ ^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$ ]] || fail "invalid runtime ID"
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid manifest digest"
[[ "$integration_sha" =~ ^[0-9a-f]{64}$ ]] || fail "invalid integration attestation digest"
if [ "$channel" = stable ]; then
	[[ "$canary_sha" =~ ^[0-9a-f]{64}$ ]] || fail "invalid canary attestation digest"
fi
[ -f "$catalog_in" ] && [ ! -L "$catalog_in" ] || fail "input catalog is not a regular file"
[ ! -e "$catalog_out" ] || fail "output catalog already exists"
for cmd in curl gh jq python3 sha256sum wc; do command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd"; done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ] && command -v check-jsonschema >/dev/null 2>&1; then schema_validator="$(command -v check-jsonschema)"
elif [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || fail "missing required command: check-jsonschema"
"$repo_root/scripts/verify-runtime-catalog.sh" "$catalog_in"

if jq -e --arg runtime "$runtime_id" '.revocations[] | select(.runtime_id==$runtime)' "$catalog_in" >/dev/null; then
	fail "revoked runtime IDs cannot be promoted"
fi
if [ "$channel" = candidate ] && jq -e --arg runtime "$runtime_id" '.architectures.amd64.channels.stable | select(.runtime_id==$runtime)' "$catalog_in" >/dev/null; then
	fail "stable runtimes cannot be promoted back to candidate"
fi
if [ "$channel" = stable ]; then
	jq -e --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" '
      .architectures.amd64.channels.candidate=={runtime_id:$runtime,manifest_sha256:$manifest}
    ' "$catalog_in" >/dev/null || fail "stable promotion requires the exact current candidate"
fi

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM
manifest="$tmp_dir/runtime-manifest.json"
runtime_verifier="${YEET_PROMOTION_VERIFY_RUNTIME:-$repo_root/scripts/verify-published-firecracker-runtime.sh}"
if [ "$runtime_verifier" != "$repo_root/scripts/verify-published-firecracker-runtime.sh" ] && [ "${YEET_RUNTIME_TEST_MODE:-}" != 1 ]; then
	fail "runtime verifier override requires explicit test mode"
fi
[ -x "$runtime_verifier" ] || fail "runtime verifier is unavailable"
verification="$("$runtime_verifier" "$runtime_id")"
[ "$(jq -er '.manifest_sha256' <<<"$verification")" = "$manifest_sha256" ] || fail "published runtime manifest digest mismatch"
manifest_url="https://github.com/yeetrun/yeet-vm-images/releases/download/$runtime_id/runtime-manifest.json"
manifest_record="$(jq -ce --arg url "$manifest_url" --arg sha "$manifest_sha256" '
  [.assets[]|select(.name=="runtime-manifest.json")] as $matches |
  select(($matches|length)==1) | $matches[0] |
  select(.browser_download_url==$url and .digest==("sha256:"+$sha) and
    (.size|type=="number" and .>0 and .<=1048576 and floor==.))
' <<<"$verification")" || fail "verified runtime manifest asset metadata mismatch"

download_bound() {
	local record="$1" output="$2" label="$3" url expected_size expected_digest effective_url final_host
	url="$(jq -er '.browser_download_url' <<<"$record")"; expected_size="$(jq -er '.size' <<<"$record")"; expected_digest="$(jq -er '.digest|ltrimstr("sha256:")' <<<"$record")"
	effective_url="$(curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--tlsv1.2 --connect-timeout 10 --max-time 300 --max-redirs 3 --max-filesize "$expected_size" \
		-o "$output" --write-out '%{url_effective}' "$url")" || fail "bounded download failed: $label"
	final_host="$(python3 - "$effective_url" <<'PY'
import sys
from urllib.parse import urlsplit
url = urlsplit(sys.argv[1])
if url.scheme != "https" or url.username is not None or url.password is not None or url.hostname is None or url.port not in (None, 443):
    raise SystemExit(1)
print(url.hostname)
PY
	)" || fail "download ended at an invalid URL: $label"
	case "$final_host" in github.com|objects.githubusercontent.com|release-assets.githubusercontent.com) ;; *) fail "download ended at an unexpected host: $label" ;; esac
	[ "$(wc -c <"$output" | tr -d ' ')" = "$expected_size" ] || fail "downloaded asset size mismatch: $label"
	[ "$(sha256sum "$output" | awk '{print $1}')" = "$expected_digest" ] || fail "downloaded asset digest mismatch: $label"
}

download_bound "$manifest_record" "$manifest" runtime-manifest.json
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-manifest.schema.json" "$manifest" >/dev/null || fail "runtime manifest is not schema-valid"
jq -e --arg runtime "$runtime_id" '.runtime_id==$runtime and .architecture=="amd64" and .support.state=="supported"' "$manifest" >/dev/null || fail "runtime manifest identity or support mismatch"
upstream_version="$(jq -er '.upstream.version' "$manifest")"

verify_attestation() {
	local kind="$1" url="$2" requested_sha="$3" prefix run_id tag release attestation_record checksum_record
	prefix="https://github.com/yeetrun/yeet-vm-images/releases/download/$runtime_id-$kind-"
	[[ "$url" =~ ^${prefix}([1-9][0-9]*)/runtime-attestation[.]json$ ]] || fail "$kind attestation URL does not bind the runtime and run"
	run_id="${BASH_REMATCH[1]}"; tag="$runtime_id-$kind-$run_id"; release="$tmp_dir/$kind-release.json"
	gh api "repos/yeetrun/yeet-vm-images/releases/tags/$tag" >"$release"
	jq -e --arg tag "$tag" '
      .tag_name==$tag and .draft==false and .prerelease==false and .immutable==true and .published_at!=null and
      ([.assets[].name]|sort)==["runtime-attestation.json","runtime-attestation.sha256"] and
      ([.assets[].name]|length)==([.assets[].name]|unique|length) and
      all(.assets[]; .state=="uploaded" and (.id|type=="number" and .>0 and floor==.) and (.size|type=="number" and .>0 and .<=1048576 and floor==.) and
        (.digest|test("^sha256:[0-9a-f]{64}$")) and
        .url==("https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/"+(.id|tostring)) and
        .browser_download_url==("https://github.com/yeetrun/yeet-vm-images/releases/download/"+$tag+"/"+.name))
    ' "$release" >/dev/null || fail "$kind attestation release metadata mismatch"
	attestation_record="$(jq -ce --arg sha "$requested_sha" '.assets[]|select(.name=="runtime-attestation.json" and .digest==("sha256:"+$sha))' "$release")" || fail "$kind attestation asset digest mismatch"
	checksum_record="$(jq -ce '.assets[]|select(.name=="runtime-attestation.sha256")' "$release")" || fail "$kind attestation checksum asset is missing"
	download_bound "$attestation_record" "$tmp_dir/$kind-attestation.json" "$kind runtime-attestation.json"
	download_bound "$checksum_record" "$tmp_dir/$kind-attestation.sha256" "$kind runtime-attestation.sha256"
	[ "$(cat "$tmp_dir/$kind-attestation.sha256")" = "$requested_sha  runtime-attestation.json" ] || fail "$kind attestation checksum line mismatch"

	gh api "repos/yeetrun/yeet-vm-images/git/ref/tags/$tag" >"$tmp_dir/$kind-ref.json"
	local ref_type ref_sha depth=0
	ref_type="$(jq -er '.object.type' "$tmp_dir/$kind-ref.json")"; ref_sha="$(jq -er '.object.sha' "$tmp_dir/$kind-ref.json")"
	while [ "$ref_type" = tag ]; do
		depth=$((depth + 1)); [ "$depth" -le 4 ] || fail "$kind attestation tag peel depth exceeded"
		gh api "repos/yeetrun/yeet-vm-images/git/tags/$ref_sha" >"$tmp_dir/$kind-tag-$depth.json"
		ref_type="$(jq -er '.object.type' "$tmp_dir/$kind-tag-$depth.json")"; ref_sha="$(jq -er '.object.sha' "$tmp_dir/$kind-tag-$depth.json")"
	done
	[ "$ref_type" = commit ] || fail "$kind attestation tag does not resolve to a commit"
	"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-attestation.schema.json" "$tmp_dir/$kind-attestation.json" >/dev/null || fail "$kind attestation is not schema-valid"
	jq -e --arg kind "$kind" --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" --arg run "$run_id" '
      .kind==$kind and .result=="passed" and
      .subject=={runtime_id:$runtime,manifest_sha256:$manifest} and
      .source.repository=="yeetrun/yeet-vm-images" and .source.workflow_run==$run and
      .tested_yeet.repository=="yeetrun/yeet" and all(.matrix[]; .=="passed") and
      ((.started_at|fromdateiso8601) <= (.completed_at|fromdateiso8601))
    ' "$tmp_dir/$kind-attestation.json" >/dev/null || fail "$kind attestation does not bind the requested subject"
	[ "$ref_sha" = "$(jq -er '.source.commit' "$tmp_dir/$kind-attestation.json")" ] || fail "$kind attestation tag target differs from source commit"
}

verify_attestation integration "$integration_url" "$integration_sha"
if [ "$channel" = stable ]; then verify_attestation canary "$canary_url" "$canary_sha"; fi

existing_count="$(jq --arg runtime "$runtime_id" '[.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)]|length' "$catalog_in")"
[ "$existing_count" -le 1 ] || fail "catalog contains duplicate runtime IDs"
entry="$(jq -n --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" --arg version "$upstream_version" \
	--arg integration_url "$integration_url" --arg integration_sha "$integration_sha" '
  {runtime_id:$runtime,
   manifest_url:("https://github.com/yeetrun/yeet-vm-images/releases/download/"+$runtime+"/runtime-manifest.json"),
   manifest_sha256:$manifest,upstream_version:$version,support:"supported",
   integration_attestation_url:$integration_url,integration_attestation_sha256:$integration_sha,
   canary_attestation_url:null,canary_attestation_sha256:null}
')"

if [ "$channel" = candidate ]; then
	if [ "$existing_count" = 1 ]; then
		existing="$(jq -c --arg runtime "$runtime_id" '.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)' "$catalog_in")"
		[ "$existing" = "$(jq -c . <<<"$entry")" ] || fail "catalog already contains a conflicting runtime entry"
	fi
else
	[ "$existing_count" = 1 ] || fail "stable promotion requires the candidate runtime entry"
	jq -e --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" --arg version "$upstream_version" \
		--arg manifest_url "$manifest_url" --arg integration_url "$integration_url" --arg integration_sha "$integration_sha" \
		--arg canary_url "$canary_url" --arg canary_sha "$canary_sha" '
      .architectures.amd64.runtimes[] | select(.runtime_id==$runtime) |
      .manifest_sha256==$manifest and .manifest_url==$manifest_url and .upstream_version==$version and .support=="supported" and
      .integration_attestation_url==$integration_url and .integration_attestation_sha256==$integration_sha and
      ((.canary_attestation_url==null and .canary_attestation_sha256==null) or
       (.canary_attestation_url==$canary_url and .canary_attestation_sha256==$canary_sha))
    ' "$catalog_in" >/dev/null || fail "catalog candidate entry conflicts with stable promotion evidence"
fi

out_parent="$(dirname "$catalog_out")"
[ -d "$out_parent" ] || fail "catalog output parent does not exist"
tmp_out="$(mktemp "$out_parent/.runtime-catalog.XXXXXX")"
if [ "$channel" = candidate ]; then
	jq --argjson entry "$entry" --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" '
      if ([.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)]|length)==0
      then .architectures.amd64.runtimes += [$entry]
      else . end |
      .architectures.amd64.channels.candidate={runtime_id:$runtime,manifest_sha256:$manifest}
    ' "$catalog_in" >"$tmp_out"
else
	jq --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" --arg canary_url "$canary_url" --arg canary_sha "$canary_sha" '
      (.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)).canary_attestation_url=$canary_url |
      (.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)).canary_attestation_sha256=$canary_sha |
      .architectures.amd64.channels.stable={runtime_id:$runtime,manifest_sha256:$manifest}
    ' "$catalog_in" >"$tmp_out"
fi
"$repo_root/scripts/verify-runtime-catalog.sh" "$tmp_out"
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-catalog.schema.json" "$tmp_out" >/dev/null || fail "promoted catalog is not schema-valid"
mv "$tmp_out" "$catalog_out"
