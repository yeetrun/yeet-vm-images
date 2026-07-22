#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 [--kind integration|canary] --runtime-id ID --manifest-sha256 SHA256 --target COMMIT --run-id RUN_ID --yeet-commit COMMIT --ubuntu-guest-release ID --nixos-guest-release ID --current-kernel-release ID --previous-kernel-release ID --attestation FILE --checksum FILE" >&2; exit 2; }
fail() { echo "Firecracker runtime attestation publish failed: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
kind=integration runtime_id="" manifest_sha256="" target="" run_id="" yeet_commit="" ubuntu_guest_release="" nixos_guest_release="" current_kernel_release="" previous_kernel_release="" attestation="" checksum=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--kind) [ "$#" -ge 2 ] || usage; kind="$2"; shift 2 ;;
		--runtime-id) [ "$#" -ge 2 ] || usage; runtime_id="$2"; shift 2 ;;
		--manifest-sha256) [ "$#" -ge 2 ] || usage; manifest_sha256="$2"; shift 2 ;;
		--target) [ "$#" -ge 2 ] || usage; target="$2"; shift 2 ;;
		--run-id) [ "$#" -ge 2 ] || usage; run_id="$2"; shift 2 ;;
		--yeet-commit) [ "$#" -ge 2 ] || usage; yeet_commit="$2"; shift 2 ;;
		--ubuntu-guest-release) [ "$#" -ge 2 ] || usage; ubuntu_guest_release="$2"; shift 2 ;;
		--nixos-guest-release) [ "$#" -ge 2 ] || usage; nixos_guest_release="$2"; shift 2 ;;
		--current-kernel-release) [ "$#" -ge 2 ] || usage; current_kernel_release="$2"; shift 2 ;;
		--previous-kernel-release) [ "$#" -ge 2 ] || usage; previous_kernel_release="$2"; shift 2 ;;
		--attestation) [ "$#" -ge 2 ] || usage; attestation="$2"; shift 2 ;;
		--checksum) [ "$#" -ge 2 ] || usage; checksum="$2"; shift 2 ;;
		*) usage ;;
	esac
done
for required in runtime_id manifest_sha256 target run_id yeet_commit ubuntu_guest_release nixos_guest_release current_kernel_release previous_kernel_release attestation checksum; do [ -n "${!required}" ] || usage; done
[[ "$runtime_id" =~ ^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$ ]] || fail "invalid runtime ID"
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid manifest digest"
[[ "$target" =~ ^[0-9a-f]{40}$ ]] || fail "target must be a full lowercase commit"
[[ "$run_id" =~ ^[1-9][0-9]*$ ]] || fail "invalid workflow run ID"
case "$kind" in integration|canary) ;; *) fail "invalid attestation kind" ;; esac
[ -f "$attestation" ] && [ ! -L "$attestation" ] || fail "attestation is not a regular file"
[ -f "$checksum" ] && [ ! -L "$checksum" ] || fail "checksum is not a regular file"

repository=yeetrun/yeet-vm-images
if [ "$kind" = integration ]; then
	workflow_file=.github/workflows/test-firecracker-runtime-kvm.yml
	publisher_job=publish-firecracker-runtime-integration
	identity_prefix=YEET_INTEGRATION_WORKFLOW
else
	workflow_file=.github/workflows/canary-firecracker-runtime.yml
	publisher_job=publish-firecracker-runtime-canary
	identity_prefix=YEET_CANARY_WORKFLOW
fi
workflow="$repository/$workflow_file@refs/heads/main"
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_REPOSITORY:-}" = "$repository" ] || fail "publisher requires the reviewed Actions repository"
[ "${GITHUB_JOB:-}" = "$publisher_job" ] || fail "publisher requires the reviewed publishing job"
[ "${GITHUB_WORKFLOW_REF:-}" = "$workflow" ] || fail "publisher requires the approved workflow on main"
repository_var="${identity_prefix}_REPOSITORY"; file_var="${identity_prefix}_FILE_PATH"; ref_var="${identity_prefix}_REF"; sha_var="${identity_prefix}_SHA"
[ "${!repository_var:-}" = "$repository" ] || fail "workflow repository identity mismatch"
[ "${!file_var:-}" = "$workflow_file" ] || fail "workflow file identity mismatch"
[ "${!ref_var:-}" = "$workflow" ] || fail "workflow ref identity mismatch"
[ "${!sha_var:-}" = "$target" ] || fail "workflow SHA identity mismatch"
[ "${GITHUB_RUN_ID:-}" = "$run_id" ] || fail "run ID differs from the native workflow run"
[ -n "${GH_TOKEN:-}" ] || fail "publisher requires a repository-scoped GitHub App token"
unset GITHUB_TOKEN
for cmd in gh jq sha256sum wc; do require "$cmd"; done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ] && command -v check-jsonschema >/dev/null 2>&1; then schema_validator="$(command -v check-jsonschema)"
elif [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || fail "missing required command: check-jsonschema"
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-attestation.schema.json" "$attestation" >/dev/null || fail "attestation is not schema-valid"
jq -e --arg kind "$kind" --arg runtime "$runtime_id" --arg manifest "$manifest_sha256" --arg commit "$target" --arg run "$run_id" \
	--arg yeet "$yeet_commit" --arg ubuntu "$ubuntu_guest_release" --arg nixos "$nixos_guest_release" \
	--arg current "$current_kernel_release" --arg previous "$previous_kernel_release" '
	  .kind == $kind and .result == "passed" and
  .subject == {runtime_id:$runtime,manifest_sha256:$manifest} and
  .source == {repository:"yeetrun/yeet-vm-images",commit:$commit,workflow_run:$run} and
  .tested_yeet == {repository:"yeetrun/yeet",commit:$yeet} and
  .artifacts == {ubuntu_guest_release:$ubuntu,nixos_guest_release:$nixos,current_kernel_release:$current,previous_kernel_release:$previous} and
  all(.matrix[]; . == "passed") and
  ((.started_at | fromdateiso8601) <= (.completed_at | fromdateiso8601))
' "$attestation" >/dev/null || fail "attestation does not bind the requested subject and workflow"
attestation_sha="$(sha256sum "$attestation" | awk '{print $1}')"
[ "$(cat "$checksum")" = "$attestation_sha  runtime-attestation.json" ] || fail "checksum file must contain the exact attestation checksum line"

response_parser="$repo_root/scripts/parse-github-api-response.py"
[ -x "$response_parser" ] || fail "response parser is unavailable"
tag="$runtime_id-$kind-$run_id"
tmp_dir="$(mktemp -d)"
tag_created=false release_id=""
cleanup() {
	status=$?
	if [ "$status" -ne 0 ] && [ "$tag_created" = true ]; then
		echo "Preserved partial $kind evidence $tag and release ID ${release_id:-not-created}. Start a new manual recovery run so it receives a new run ID; nothing was overwritten or deleted." >&2
	fi
	rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

api_call() {
	local expected="$1" method="$2" endpoint="$3" output="$4"
	shift 4
	local raw="$tmp_dir/response-$RANDOM.raw"
	gh api --include --method "$method" "$endpoint" "$@" >"$raw" || fail "GitHub API $method $endpoint failed; no overwrite was attempted"
	"$response_parser" "$raw" "$expected" "$output"
}
immutable="$tmp_dir/immutable.json"
api_call 200 GET "repos/$repository/immutable-releases" "$immutable" >/dev/null
jq -e '.enabled == true' "$immutable" >/dev/null || fail "repository immutable releases are not enabled"

ref_request="$tmp_dir/ref-request.json"
jq -n --arg ref "refs/tags/$tag" --arg sha "$target" '{ref:$ref,sha:$sha}' >"$ref_request"
created_ref="$tmp_dir/created-ref.json"
api_call 201 POST "repos/$repository/git/refs" "$created_ref" --input "$ref_request" >/dev/null
tag_created=true

resolve_ref() {
	local ref_json="$tmp_dir/ref.json" type sha tag_json depth=0
	api_call 200 GET "repos/$repository/git/ref/tags/$tag" "$ref_json" >/dev/null
	type="$(jq -er '.object.type' "$ref_json")"; sha="$(jq -er '.object.sha' "$ref_json")"
	while [ "$type" = tag ]; do
		depth=$((depth + 1)); [ "$depth" -le 4 ] || fail "tag peel depth exceeded"
		tag_json="$tmp_dir/tag-$depth.json"
		api_call 200 GET "repos/$repository/git/tags/$sha" "$tag_json" >/dev/null
		type="$(jq -er '.object.type' "$tag_json")"; sha="$(jq -er '.object.sha' "$tag_json")"
	done
	[ "$type" = commit ] && [ "$sha" = "$target" ] || fail "attestation tag target mismatch"
}
resolve_ref

release_request="$tmp_dir/release-request.json"
jq -n --arg tag "$tag" --arg target "$target" --arg kind "$kind" \
		'{tag_name:$tag,target_commitish:$target,name:$tag,body:("Passed Firecracker runtime "+$kind+" evidence."),draft:true,prerelease:false,make_latest:"false"}' >"$release_request"
release="$tmp_dir/release.json"
api_call 201 POST "repos/$repository/releases" "$release" --input "$release_request" >/dev/null
release_id="$(jq -er '.id | select(type == "number" and . > 0 and floor == .)' "$release")"
upload_url="$(jq -er '.upload_url' "$release")"
[ "$upload_url" = "https://uploads.github.com/repos/$repository/releases/$release_id/assets{?name,label}" ] || fail "release upload URL mismatch"

assets=(runtime-attestation.json runtime-attestation.sha256)
asset_path() { case "$1" in runtime-attestation.json) printf '%s\n' "$attestation" ;; runtime-attestation.sha256) printf '%s\n' "$checksum" ;; esac; }
for asset in "${assets[@]}"; do
	path="$(asset_path "$asset")"; encoded="$(jq -nr --arg value "$asset" '$value|@uri')"; uploaded="$tmp_dir/uploaded-$encoded.json"
	api_call 201 POST "https://uploads.github.com/repos/$repository/releases/$release_id/assets?name=$encoded" "$uploaded" \
		--header 'Content-Type: application/octet-stream' --input "$path" >/dev/null
	digest="sha256:$(sha256sum "$path" | awk '{print $1}')"; size="$(wc -c <"$path" | tr -d ' ')"
	jq -e --arg name "$asset" --arg digest "$digest" --argjson size "$size" \
		'.name==$name and .state=="uploaded" and .size==$size and .digest==$digest' "$uploaded" >/dev/null || fail "uploaded asset response mismatch: $asset"
done

list_assets() {
	local output="$1"
	api_call 200 GET "repos/$repository/releases/$release_id/assets?per_page=100&page=1" "$output" >/dev/null
	[ "$(jq 'length' "$output")" -lt 100 ] || fail "unexpected asset pagination"
}
verify_assets() {
	local input="$1"
	[ "$(jq 'length' "$input")" = 2 ] || fail "attestation release must contain exactly two assets"
	for asset in "${assets[@]}"; do
		path="$(asset_path "$asset")"; digest="sha256:$(sha256sum "$path" | awk '{print $1}')"; size="$(wc -c <"$path" | tr -d ' ')"
		browser="https://github.com/$repository/releases/download/$tag/$asset"
		jq -e --arg name "$asset" --arg digest "$digest" --argjson size "$size" --arg browser "$browser" --arg repo "$repository" '
          ([.[] | select(.name==$name and .state=="uploaded" and .size==$size and .digest==$digest and
            (.id|type=="number" and . > 0 and floor == .) and
            .url==("https://api.github.com/repos/"+$repo+"/releases/assets/"+(.id|tostring)) and
            .browser_download_url==$browser)] | length) == 1
        ' "$input" >/dev/null || fail "remote asset mismatch or collision: $asset"
	done
}
assets_json="$tmp_dir/assets.json"
list_assets "$assets_json"; verify_assets "$assets_json"
pre="$tmp_dir/pre.json"; api_call 200 GET "repos/$repository/releases/$release_id" "$pre" >/dev/null
jq -e --arg tag "$tag" --argjson id "$release_id" '.id==$id and .tag_name==$tag and .draft==true and .prerelease==false' "$pre" >/dev/null || fail "draft release identity mismatch"
list_assets "$assets_json"; verify_assets "$assets_json"; resolve_ref
publish_request="$tmp_dir/publish.json"; jq -n '{draft:false}' >"$publish_request"
published="$tmp_dir/published.json"; api_call 200 PATCH "repos/$repository/releases/$release_id" "$published" --input "$publish_request" >/dev/null
final="$tmp_dir/final.json"; api_call 200 GET "repos/$repository/releases/$release_id" "$final" >/dev/null
jq -e --arg tag "$tag" --argjson id "$release_id" '.id==$id and .tag_name==$tag and .draft==false and .prerelease==false and .published_at!=null and .immutable==true' "$final" >/dev/null || fail "published attestation release is not immutable and final"
list_assets "$assets_json"; verify_assets "$assets_json"; resolve_ref
