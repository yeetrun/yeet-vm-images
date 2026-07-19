#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 firecracker-vMAJOR.MINOR.PATCH-yeet-vN" >&2; exit 2; }
fail() { echo "Published Firecracker runtime verification failed: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

[ "$#" = 1 ] || usage
runtime_id="$1"
[[ "$runtime_id" =~ ^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$ ]] || fail "invalid runtime ID"
repository=yeetrun/yeet-vm-images
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$repo_root/schemas/firecracker-runtime-manifest.schema.json"
bundle_verifier="$repo_root/scripts/verify-firecracker-runtime-bundle.py"
policy="$repo_root/security/firecracker-runtime-policy.json"
policy_resolver="$repo_root/scripts/resolve-firecracker-runtime-policy.py"

if [ "${YEET_RUNTIME_TEST_MODE:-}" != 1 ] && {
	[ -n "${YEET_TEST_PUBLISHED_FIXTURE:-}" ] || [ -n "${YEET_TEST_PUBLISHED_GH_LOG:-}" ] ||
		[ -n "${YEET_TEST_PUBLISHED_CURL_LOG:-}" ] || [ -n "${YEET_TEST_RELEASE_MISSING:-}" ] ||
		[ -n "${YEET_TEST_OVERSIZED_ASSET:-}" ];
}; then
	fail "published-runtime fixture controls require explicit test mode"
fi
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_REPOSITORY:-}" = "$repository" ] || fail "verification requires the trusted GitHub Actions repository"
[ -n "${GH_TOKEN:-}" ] || fail "verification requires the read-only GitHub API token"
for command in gh curl jq sha256sum wc chmod python3; do require "$command"; done
for helper in "$bundle_verifier" "$policy_resolver"; do [ -x "$helper" ] || fail "runtime verification helper is missing"; done
[ -f "$schema" ] && [ -f "$policy" ] || fail "runtime schema or policy is missing"

schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ] && command -v check-jsonschema >/dev/null 2>&1; then schema_validator="$(command -v check-jsonschema)"
elif [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || fail "missing required command: check-jsonschema"

umask 077
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM

api_get() {
	local endpoint="$1" output="$2"
	gh api --method GET "$endpoint" >"$output" || fail "GitHub API query failed: $endpoint"
}

release_json="$tmp_dir/release.json"
api_get "repos/$repository/releases/tags/$runtime_id" "$release_json"
jq -e --arg tag "$runtime_id" '
  (.id | type == "number" and . > 0 and floor == .) and
  .tag_name == $tag and .draft == false and .prerelease == false and
  .immutable == true and
  (.published_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
' "$release_json" >/dev/null || fail "release is missing, mutable, prerelease, draft, unpublished, or has the wrong identity"
release_id="$(jq -er '.id' "$release_json")"

assets_json="$tmp_dir/assets.json"
api_get "repos/$repository/releases/$release_id/assets?per_page=100&page=1" "$assets_json"
jq -e 'type == "array" and length == 4' "$assets_json" >/dev/null || fail "release does not contain exactly four assets"

assets=(firecracker jailer runtime-manifest.json runtime-checksums.txt)
for name in "${assets[@]}"; do
	case "$name" in
		firecracker|jailer) maximum_size=134217728 ;;
		*) maximum_size=1048576 ;;
	esac
	api_prefix="https://api.github.com/repos/$repository/releases/assets/"
	browser_url="https://github.com/$repository/releases/download/$runtime_id/$name"
	record="$tmp_dir/record-${name//\//_}.json"
	jq -ce --arg name "$name" --arg api_prefix "$api_prefix" --arg browser_url "$browser_url" --argjson maximum_size "$maximum_size" '
    [.[] | select(.name == $name)] as $matches |
    select(($matches | length) == 1) | $matches[0] |
    select(.id | type == "number" and . > 0 and floor == .) |
    select(.state == "uploaded") |
    select(.url == ($api_prefix + (.id | tostring))) |
    select(.browser_download_url == $browser_url) |
    select(.size | type == "number" and . > 0 and . <= $maximum_size and floor == .) |
    select(.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$assets_json" >"$record" || fail "asset metadata is missing, duplicate, malformed, or outside bounds: $name"

	output="$tmp_dir/bundle-$name"
	expected_size="$(jq -er '.size' "$record")"
	if ! effective_url="$(curl --disable --fail --show-error --silent --location --max-redirs 3 \
		--proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 \
		--max-filesize "$expected_size" \
		--output "$output" --write-out '%{url_effective}' "$browser_url")"; then
		fail "bounded asset download failed: $name"
	fi
	final_host="$(python3 - "$effective_url" <<'PY'
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.argv[1])
if (
    url.scheme != "https"
    or url.username is not None
    or url.password is not None
    or url.hostname is None
    or url.port not in (None, 443)
):
    raise SystemExit(1)
print(url.hostname)
PY
	)" || fail "asset download ended at an invalid URL: $name"
	case "$final_host" in
		github.com|objects.githubusercontent.com|release-assets.githubusercontent.com) ;;
		*) fail "asset download ended at an untrusted host: $name" ;;
	esac
	actual_size="$(wc -c <"$output" | tr -d ' ')"
	[ "$actual_size" = "$expected_size" ] || fail "downloaded asset size mismatch: $name"
	expected_digest="$(jq -er '.digest' "$record")"
	expected_digest="${expected_digest#sha256:}"
	actual_digest="$(sha256sum "$output" | awk '{print $1}')"
	[ "$actual_digest" = "$expected_digest" ] || fail "downloaded asset digest mismatch: $name"
done

bundle="$tmp_dir/bundle"
mkdir "$bundle"
for name in "${assets[@]}"; do mv "$tmp_dir/bundle-$name" "$bundle/$name"; done
chmod 0755 "$bundle/firecracker" "$bundle/jailer"
chmod 0644 "$bundle/runtime-manifest.json" "$bundle/runtime-checksums.txt"

"$schema_validator" --schemafile "$schema" "$bundle/runtime-manifest.json" >/dev/null || fail "published runtime manifest is not schema-valid"
provenance_commit="$(jq -er '.provenance.commit | select(type == "string" and test("^[0-9a-f]{40}$"))' "$bundle/runtime-manifest.json")" || fail "manifest provenance commit is invalid"
"$bundle_verifier" "$bundle" "$runtime_id" "$provenance_commit" "$policy" "$policy_resolver"

ref_json="$tmp_dir/ref.json"
api_get "repos/$repository/git/ref/tags/$runtime_id" "$ref_json"
object_type="$(jq -er '.object.type | select(. == "commit" or . == "tag")' "$ref_json")" || fail "runtime tag object type is invalid"
object_sha="$(jq -er '.object.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' "$ref_json")" || fail "runtime tag object SHA is invalid"
depth=0
while [ "$object_type" = tag ]; do
	depth=$((depth + 1)); [ "$depth" -le 4 ] || fail "runtime tag peel depth exceeded"
	tag_json="$tmp_dir/tag-$depth.json"
	api_get "repos/$repository/git/tags/$object_sha" "$tag_json"
	object_type="$(jq -er '.object.type | select(. == "commit" or . == "tag")' "$tag_json")" || fail "peeled tag object type is invalid"
	object_sha="$(jq -er '.object.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' "$tag_json")" || fail "peeled tag object SHA is invalid"
done
[ "$object_sha" = "$provenance_commit" ] || fail "runtime tag does not resolve to the manifest provenance commit"

manifest_sha256="$(sha256sum "$bundle/runtime-manifest.json" | awk '{print $1}')"
jq -n --arg runtime_id "$runtime_id" --argjson release_id "$release_id" \
	--arg provenance_commit "$provenance_commit" --arg manifest_sha256 "$manifest_sha256" \
	'{runtime_id:$runtime_id,release_id:$release_id,provenance_commit:$provenance_commit,manifest_sha256:$manifest_sha256}'
