#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 --runtime-id ID --target COMMIT --notes-file FILE --out DIR" >&2; exit 2; }
fail() { echo "Firecracker runtime publish failed: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$repo_root/schemas/firecracker-runtime-manifest.schema.json"
bundle_verifier="$repo_root/scripts/verify-firecracker-runtime-bundle.py"
policy_resolver="$repo_root/scripts/resolve-firecracker-runtime-policy.py"
policy_file="$repo_root/security/firecracker-runtime-policy.json"
response_parser="$repo_root/scripts/parse-github-api-response.py"
repository="yeetrun/yeet-vm-images"
runtime_id="" target="" notes_file="" out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--runtime-id) [ "$#" -ge 2 ] || usage; runtime_id="$2"; shift 2 ;;
		--target) [ "$#" -ge 2 ] || usage; target="$2"; shift 2 ;;
		--notes-file) [ "$#" -ge 2 ] || usage; notes_file="$2"; shift 2 ;;
		--out) [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
		--clobber|--overwrite) fail "overwrite is forbidden; use the next packaging revision" ;;
		--help|-h) usage ;;
		*) usage ;;
	esac
done
[ -n "$runtime_id" ] && [ -n "$target" ] && [ -n "$notes_file" ] && [ -n "$out" ] || usage
[[ "$runtime_id" =~ ^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$ ]] || fail "invalid runtime ID"
[[ "$target" =~ ^[0-9a-f]{40}$ ]] || fail "target must be a full lowercase commit"
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_REPOSITORY:-}" = "$repository" ] || fail "publisher requires the trusted GitHub Actions repository"
[ "${GITHUB_JOB:-}" = publish-firecracker-runtime ] || fail "publisher requires the reviewed publishing job"
[ "${GITHUB_WORKFLOW_REF:-}" = "$repository/.github/workflows/sync-latest-stable-firecracker.yml@refs/heads/main" ] || fail "publisher requires the approved scheduled/manual caller on main"
[ "${YEET_RUNTIME_WORKFLOW_REPOSITORY:-}" = "$repository" ] || fail "publisher requires the reviewed called-workflow repository"
[ "${YEET_RUNTIME_WORKFLOW_FILE_PATH:-}" = .github/workflows/build-firecracker-runtime.yml ] || fail "publisher requires the reviewed called-workflow file path"
[ "${YEET_RUNTIME_WORKFLOW_REF:-}" = "$repository/.github/workflows/build-firecracker-runtime.yml@refs/heads/main" ] || fail "publisher requires the approved full called-workflow ref"
[ "${YEET_RUNTIME_WORKFLOW_SHA:-}" = "$target" ] || fail "called-workflow SHA does not match the exact target commit"
[ "${GITHUB_SHA:-}" = "$target" ] || fail "release target does not match GITHUB_SHA"
[ -n "${GH_TOKEN:-}" ] || fail "publisher requires an explicit repository-scoped GitHub App installation token"
unset GITHUB_TOKEN
[ -f "$notes_file" ] && [ ! -L "$notes_file" ] || fail "notes file is not regular"
[ -d "$out" ] && [ ! -L "$out" ] || fail "bundle is not a real directory"
for command in gh jq sha256sum python3; do require "$command"; done
for helper in "$bundle_verifier" "$policy_resolver" "$response_parser"; do [ -x "$helper" ] || fail "runtime verification helper is missing"; done

schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ] && command -v check-jsonschema >/dev/null 2>&1; then schema_validator="$(command -v check-jsonschema)"
elif [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || fail "missing required command: check-jsonschema"
"$schema_validator" --schemafile "$schema" "$out/runtime-manifest.json" >/dev/null || fail "runtime manifest is not schema-valid"
"$bundle_verifier" "$out" "$runtime_id" "$target" "$policy_file" "$policy_resolver"

umask 077
tmp_dir="$(mktemp -d)"
tag_created=false
release_id=""
cleanup() {
	status=$?
	if [ "$status" -ne 0 ] && [ "$tag_created" = true ]; then
		echo "Preserved immutable tag refs/tags/$runtime_id and draft release ID ${release_id:-not-created}; packaging revision consumed. Inspect the preserved draft, then use the next packaging revision. No tag, release, or asset was deleted." >&2
	fi
	rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

api_call() {
	local expected="$1" method="$2" endpoint="$3" body_output="$4"
	shift 4
	local raw="$tmp_dir/response-$RANDOM.raw"
	if ! gh api --include --method "$method" "$endpoint" "$@" >"$raw"; then
		fail "GitHub API $method $endpoint failed (collision, authorization, or validation error); no overwrite was attempted"
	fi
	"$response_parser" "$raw" "$expected" "$body_output"
}

immutable_json="$tmp_dir/immutable.json"
api_call 200 GET "repos/$repository/immutable-releases" "$immutable_json" >/dev/null
jq -e '.enabled == true' "$immutable_json" >/dev/null || fail "repository immutable releases are not enabled"

ref_request="$tmp_dir/ref-request.json"
jq -n --arg ref "refs/tags/$runtime_id" --arg sha "$target" '{ref:$ref,sha:$sha}' >"$ref_request"
created_ref="$tmp_dir/created-ref.json"
api_call 201 POST "repos/$repository/git/refs" "$created_ref" --input "$ref_request" >/dev/null
tag_created=true

resolve_ref() {
	local expected_target="$1" ref_json="$tmp_dir/ref.json" object_type object_sha tag_json depth=0
	api_call 200 GET "repos/$repository/git/ref/tags/$runtime_id" "$ref_json" >/dev/null
	object_type="$(jq -er '.object.type' "$ref_json")"
	object_sha="$(jq -er '.object.sha' "$ref_json")"
	while [ "$object_type" = tag ]; do
		depth=$((depth + 1)); [ "$depth" -le 4 ] || fail "tag peel depth exceeded"
		tag_json="$tmp_dir/tag-object-$depth.json"
		api_call 200 GET "repos/$repository/git/tags/$object_sha" "$tag_json" >/dev/null
		object_type="$(jq -er '.object.type' "$tag_json")"
		object_sha="$(jq -er '.object.sha' "$tag_json")"
	done
	[ "$object_type" = commit ] && [ "$object_sha" = "$expected_target" ] || fail "runtime tag does not resolve to the exact target commit"
}
resolve_ref "$target"

release_request="$tmp_dir/release-request.json"
notes="$(cat "$notes_file")"
jq -n --arg tag "$runtime_id" --arg target "$target" --arg name "$runtime_id" --arg body "$notes" \
	'{tag_name:$tag,target_commitish:$target,name:$name,body:$body,draft:true,prerelease:false,make_latest:"false"}' >"$release_request"
release_json="$tmp_dir/release-created.json"
api_call 201 POST "repos/$repository/releases" "$release_json" --input "$release_request" >/dev/null
release_id="$(jq -er '.id | select(type == "number" and . > 0 and floor == .)' "$release_json")" || fail "release creation did not return a numeric ID"
upload_url="$(jq -er '.upload_url' "$release_json")" || fail "release creation omitted upload URL"
expected_upload="https://uploads.github.com/repos/$repository/releases/$release_id/assets{?name,label}"
[ "$upload_url" = "$expected_upload" ] || fail "release upload URL is not pinned to the returned release ID"

assets=(firecracker jailer runtime-manifest.json runtime-checksums.txt)
for asset in "${assets[@]}"; do
	encoded_name="$(jq -nr --arg value "$asset" '$value | @uri')"
	uploaded="$tmp_dir/uploaded-$encoded_name.json"
	api_call 201 POST "https://uploads.github.com/repos/$repository/releases/$release_id/assets?name=$encoded_name" "$uploaded" \
		--header 'Content-Type: application/octet-stream' --input "$out/$asset" >/dev/null
	digest="sha256:$(sha256sum "$out/$asset" | awk '{print $1}')"
	size="$(wc -c <"$out/$asset" | tr -d ' ')"
	jq -e --arg name "$asset" --arg digest "$digest" --argjson size "$size" \
		'.name == $name and .state == "uploaded" and .size == $size and .digest == $digest' "$uploaded" >/dev/null || fail "uploaded asset response mismatch: $asset"
done

list_assets() {
	local output="$1" page_json="$tmp_dir/assets-page.json"
	api_call 200 GET "repos/$repository/releases/$release_id/assets?per_page=100&page=1" "$page_json" >/dev/null
	cp "$page_json" "$output"
	[ "$(jq 'length' "$page_json")" -lt 100 ] || fail "unexpected asset pagination"
}
verify_assets() {
	local json="$1"
	[ "$(jq 'length' "$json")" = 4 ] || fail "release must contain exactly four assets"
	for asset in "${assets[@]}"; do
		digest="sha256:$(sha256sum "$out/$asset" | awk '{print $1}')"; size="$(wc -c <"$out/$asset" | tr -d ' ')"
		jq -e --arg name "$asset" --arg digest "$digest" --argjson size "$size" \
			'([.[] | select(.name == $name and .state == "uploaded" and .size == $size and .digest == $digest)] | length) == 1' "$json" >/dev/null || fail "remote asset mismatch or collision: $asset"
	done
}
assets_json="$tmp_dir/assets.json"
list_assets "$assets_json"; verify_assets "$assets_json"

prepublish="$tmp_dir/prepublish.json"
api_call 200 GET "repos/$repository/releases/$release_id" "$prepublish" >/dev/null
jq -e --arg tag "$runtime_id" --argjson id "$release_id" '.id == $id and .tag_name == $tag and .draft == true' "$prepublish" >/dev/null || fail "draft release identity mismatch"
list_assets "$assets_json"; verify_assets "$assets_json"
resolve_ref "$target"
publish_request="$tmp_dir/publish-request.json"
jq -n '{draft:false}' >"$publish_request"
published="$tmp_dir/published.json"
api_call 200 PATCH "repos/$repository/releases/$release_id" "$published" --input "$publish_request" >/dev/null

final="$tmp_dir/final.json"
api_call 200 GET "repos/$repository/releases/$release_id" "$final" >/dev/null
jq -e --arg tag "$runtime_id" --argjson id "$release_id" \
	'.id == $id and .tag_name == $tag and .draft == false and .published_at != null and .immutable == true' "$final" >/dev/null || fail "published release is not immutable and final"
list_assets "$assets_json"; verify_assets "$assets_json"
resolve_ref "$target"
