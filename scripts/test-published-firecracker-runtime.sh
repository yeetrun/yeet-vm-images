#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs intentionally use jq variables.
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/scripts/verify-published-firecracker-runtime.sh"
manifest_schema="$repo_root/schemas/firecracker-runtime-manifest.schema.json"
schema_validator="${CHECK_JSONSCHEMA:-$(command -v check-jsonschema || true)}"
if [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || { echo "missing check-jsonschema" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

fail() { echo "Published Firecracker runtime test failed: $*" >&2; exit 1; }
runtime_id=firecracker-v1.16.1-yeet-v1
target=0123456789abcdef0123456789abcdef01234567
tag_object=89abcdef0123456789abcdef0123456789abcdef
base="$tmp_dir/base"
mkdir -p "$base/assets"

printf 'verified firecracker fixture\n' >"$base/assets/firecracker"
printf 'verified jailer fixture\n' >"$base/assets/jailer"
chmod 0755 "$base/assets/firecracker" "$base/assets/jailer"
firecracker_sha="$(sha256sum "$base/assets/firecracker" | awk '{print $1}')"
jailer_sha="$(sha256sum "$base/assets/jailer" | awk '{print $1}')"
jq -n \
	--arg runtime_id "$runtime_id" --arg target "$target" \
	--arg firecracker_sha "$firecracker_sha" --arg jailer_sha "$jailer_sha" '
  {schema_version:1,runtime_id:$runtime_id,architecture:"amd64",
   upstream:{repository:"firecracker-microvm/firecracker",version:"v1.16.1",tag:"v1.16.1",
             commit:"1111111111111111111111111111111111111111",
             archive_url:"https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.1/firecracker-v1.16.1-x86_64.tgz",
             archive_sha256:("a"*64),
             checksum_url:"https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.1/firecracker-v1.16.1-x86_64.tgz.sha256.txt",
             tag_signature:{status:"signed",fingerprint:"0123456789ABCDEF0123456789ABCDEF01234567"}},
   components:{firecracker:{path:"firecracker",sha256:$firecracker_sha,version_output:"Firecracker v1.16.1"},
               jailer:{path:"jailer",sha256:$jailer_sha,version_output:"Jailer v1.16.1"}},
   classification:{production_release:true,default_seccomp:true},
   support:{state:"supported",policy_url:"https://github.com/firecracker-microvm/firecracker/blob/main/docs/RELEASE_POLICY.md"},
   provenance:{repository:"yeetrun/yeet-vm-images",commit:$target,workflow_run:"123456789"}}
' >"$base/assets/runtime-manifest.json"
chmod 0644 "$base/assets/runtime-manifest.json"
(
	cd "$base/assets"
	sha256sum firecracker jailer runtime-manifest.json >runtime-checksums.txt
	chmod 0644 runtime-checksums.txt
)

asset_record() {
	local name="$1" id="$2" size digest path
	path="$base/assets/$name"
	size="$(wc -c <"$path" | tr -d ' ')"
	digest="sha256:$(sha256sum "$path" | awk '{print $1}')"
	jq -nc --arg name "$name" --argjson id "$id" --argjson size "$size" --arg digest "$digest" --arg runtime_id "$runtime_id" \
		'{id:$id,name:$name,state:"uploaded",size:$size,digest:$digest,
          url:("https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/"+($id|tostring)),
          browser_download_url:("https://github.com/yeetrun/yeet-vm-images/releases/download/"+$runtime_id+"/"+$name)}'
}
{
	asset_record firecracker 1001
	asset_record jailer 1002
	asset_record runtime-manifest.json 1003
	asset_record runtime-checksums.txt 1004
} | jq -s . >"$base/assets.json"
jq -n --arg tag "$runtime_id" \
	'{id:42,tag_name:$tag,draft:false,prerelease:false,immutable:true,
      published_at:"2026-07-19T20:00:00Z"}' >"$base/release.json"
jq -n --arg sha "$tag_object" '{object:{type:"tag",sha:$sha}}' >"$base/ref.json"
jq -n --arg sha "$target" '{object:{type:"commit",sha:$sha}}' >"$base/tag-object.json"

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
[ "${YEET_RUNTIME_TEST_MODE:-}" = 1 ] || { echo "published-runtime mock requires explicit test mode" >&2; exit 98; }
: "${YEET_TEST_PUBLISHED_FIXTURE:?}" "${YEET_TEST_PUBLISHED_GH_LOG:?}"
printf 'gh %s\n' "$*" >>"$YEET_TEST_PUBLISHED_GH_LOG"
[ "$1" = api ] || exit 97
shift
method="" endpoint="" headers=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--method) method="$2"; shift 2 ;;
		--header) headers+=("$2"); shift 2 ;;
		-*) exit 96 ;;
		*) [ -z "$endpoint" ] || exit 95; endpoint="$1"; shift ;;
	esac
done
[ "$method" = GET ] && [ -n "$endpoint" ] || exit 94
fixture="$YEET_TEST_PUBLISHED_FIXTURE"
case "$endpoint" in
	repos/yeetrun/yeet-vm-images/releases/tags/firecracker-v1.16.1-yeet-v1)
		[ "${YEET_TEST_RELEASE_MISSING:-}" != 1 ] || exit 1
		cat "$fixture/release.json"
		;;
	"repos/yeetrun/yeet-vm-images/releases/42/assets?per_page=100&page=1") cat "$fixture/assets.json" ;;
	repos/yeetrun/yeet-vm-images/releases/assets/*)
		printf '%s\n' "${headers[@]}" | grep -Fxq 'Accept: application/octet-stream' || exit 93
		id="${endpoint##*/}"
		name="$(jq -er --argjson id "$id" '.[] | select(.id == $id) | .name' "$fixture/assets.json")"
		cat "$fixture/assets/$name"
		;;
	repos/yeetrun/yeet-vm-images/git/ref/tags/firecracker-v1.16.1-yeet-v1) cat "$fixture/ref.json" ;;
	repos/yeetrun/yeet-vm-images/git/tags/*) cat "$fixture/tag-object.json" ;;
	*) echo "unexpected gh endpoint: $endpoint" >&2; exit 92 ;;
esac
MOCK_GH
chmod +x "$tmp_dir/bin/gh"

cat >"$tmp_dir/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
[ "${YEET_RUNTIME_TEST_MODE:-}" = 1 ] || { echo "published-runtime mock requires explicit test mode" >&2; exit 98; }
: "${YEET_TEST_PUBLISHED_FIXTURE:?}" "${YEET_TEST_PUBLISHED_CURL_LOG:?}"
[ "${1:-}" = --disable ] || exit 97
shift
maximum_size="" output="" write_out="" url="" max_redirs="" proto="" proto_redir="" connect_timeout="" max_time="" tls=false
while [ "$#" -gt 0 ]; do
	case "$1" in
		--fail|--show-error|--silent|--location) shift ;;
		--tlsv1.2) tls=true; shift ;;
		--max-redirs) max_redirs="$2"; shift 2 ;;
		--proto) proto="$2"; shift 2 ;;
		--proto-redir) proto_redir="$2"; shift 2 ;;
		--connect-timeout) connect_timeout="$2"; shift 2 ;;
		--max-time) max_time="$2"; shift 2 ;;
		--max-filesize) maximum_size="$2"; shift 2 ;;
		--output) output="$2"; shift 2 ;;
		--write-out) write_out="$2"; shift 2 ;;
		-*) exit 93 ;;
		*) [ -z "$url" ] || exit 96; url="$1"; shift ;;
	esac
done
[ "$max_redirs" = 3 ] && [ "$proto" = '=https' ] && [ "$proto_redir" = '=https' ] && [ "$tls" = true ] || exit 95
[ "$connect_timeout" = 10 ] && [ "$max_time" = 300 ] || exit 94
[ -n "$maximum_size" ] && [ -n "$output" ] && [ "$write_out" = '%{url_effective}' ] && [ -n "$url" ] || exit 92
name="${url##*/}"
source="$YEET_TEST_PUBLISHED_FIXTURE/assets/$name"
[ -f "$source" ] || exit 91
if [ "${YEET_TEST_OVERSIZED_ASSET:-}" = "$name" ]; then
	head -c "$maximum_size" /dev/zero >"$output"
	printf 'bounded %s at %s bytes\n' "$name" "$maximum_size" >>"$YEET_TEST_PUBLISHED_CURL_LOG"
	exit 63
fi
size="$(wc -c <"$source" | tr -d ' ')"
if [ "$size" -gt "$maximum_size" ]; then
	head -c "$maximum_size" "$source" >"$output"
	printf 'bounded %s at %s bytes\n' "$name" "$maximum_size" >>"$YEET_TEST_PUBLISHED_CURL_LOG"
	exit 63
fi
cp "$source" "$output"
printf 'downloaded %s with cap %s\n' "$name" "$maximum_size" >>"$YEET_TEST_PUBLISHED_CURL_LOG"
printf '%s' "${YEET_TEST_EFFECTIVE_URL:-$url}"
MOCK_CURL
chmod +x "$tmp_dir/bin/curl"

gh_log="$tmp_dir/gh.log"
curl_log="$tmp_dir/curl.log"
run_verifier() {
	local fixture="$1"
	shift
	YEET_RUNTIME_TEST_MODE=1 YEET_TEST_PUBLISHED_FIXTURE="$fixture" YEET_TEST_PUBLISHED_GH_LOG="$gh_log" \
		YEET_TEST_PUBLISHED_CURL_LOG="$curl_log" YEET_TEST_OVERSIZED_ASSET="${YEET_TEST_OVERSIZED_ASSET:-}" \
		YEET_TEST_EFFECTIVE_URL="${YEET_TEST_EFFECTIVE_URL:-}" \
		YEET_TEST_RELEASE_MISSING="${YEET_TEST_RELEASE_MISSING:-}" \
		GH_TOKEN=test-token GITHUB_ACTIONS=true GITHUB_REPOSITORY=yeetrun/yeet-vm-images \
		CHECK_JSONSCHEMA="$schema_validator" PATH="$tmp_dir/bin:$PATH" \
		"$verifier" "$runtime_id" "$@"
}
copy_case() { local name="$1"; local path="$tmp_dir/$name"; cp -R "$base" "$path"; echo "$path"; }
assert_failure() {
	local name="$1" fixture="$2"
	shift 2
	if run_verifier "$fixture" "$@" >/dev/null 2>&1; then fail "$name unexpectedly verified"; fi
}
update_asset_metadata() {
	local fixture="$1" name="$2" size digest tmp
	size="$(wc -c <"$fixture/assets/$name" | tr -d ' ')"
	digest="sha256:$(sha256sum "$fixture/assets/$name" | awk '{print $1}')"
	tmp="$fixture/assets.next"
	jq --arg name "$name" --argjson size "$size" --arg digest "$digest" \
		'map(if .name == $name then .size=$size | .digest=$digest else . end)' "$fixture/assets.json" >"$tmp"
	mv "$tmp" "$fixture/assets.json"
}

: >"$gh_log"
: >"$curl_log"
valid_output="$(run_verifier "$base")"
jq -e --arg runtime_id "$runtime_id" --arg target "$target" \
	'.runtime_id == $runtime_id and .provenance_commit == $target and .release_id == 42' <<<"$valid_output" >/dev/null || fail "valid fixture output mismatch"

if YEET_TEST_RELEASE_MISSING=1 run_verifier "$base" >/dev/null 2>&1; then fail "missing release unexpectedly verified"; fi
for scenario in draft mutable prerelease unpublished; do
	fixture="$(copy_case "$scenario")"
	case "$scenario" in
		draft) jq '.draft=true' "$fixture/release.json" >"$fixture/r" ;;
		mutable) jq '.immutable=false' "$fixture/release.json" >"$fixture/r" ;;
		prerelease) jq '.prerelease=true' "$fixture/release.json" >"$fixture/r" ;;
		unpublished) jq '.published_at=null' "$fixture/release.json" >"$fixture/r" ;;
	esac
	mv "$fixture/r" "$fixture/release.json"
	assert_failure "$scenario" "$fixture"
done

fixture="$(copy_case extra-asset)"; jq '. + [{id:1005,name:"extra",state:"uploaded",size:1,digest:("sha256:"+("0"*64)),url:"https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/1005",browser_download_url:"https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.16.1-yeet-v1/extra"}]' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure extra-asset "$fixture"
fixture="$(copy_case missing-asset)"; jq 'map(select(.name != "jailer"))' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure missing-asset "$fixture"
fixture="$(copy_case duplicate-asset)"; jq '. + [.[0]]' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure duplicate-asset "$fixture"
fixture="$(copy_case invalid-state)"; jq 'map(if .name == "firecracker" then .state="new" else . end)' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure invalid-state "$fixture"
fixture="$(copy_case over-bound-size)"; jq 'map(if .name == "runtime-manifest.json" then .size=1048577 else . end)' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure over-bound-size "$fixture"
fixture="$(copy_case wrong-size)"; jq 'map(if .name == "firecracker" then .size += 1 else . end)' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure wrong-size "$fixture"
fixture="$(copy_case wrong-digest)"; jq 'map(if .name == "firecracker" then .digest=("sha256:"+("0"*64)) else . end)' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure wrong-digest "$fixture"
fixture="$(copy_case wrong-api-url)"; jq 'map(if .name == "firecracker" then .url="https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/9999" else . end)' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure wrong-api-url "$fixture"
fixture="$(copy_case wrong-url)"; jq 'map(if .name == "firecracker" then .browser_download_url="https://example.invalid/firecracker" else . end)' "$fixture/assets.json" >"$fixture/a"; mv "$fixture/a" "$fixture/assets.json"; assert_failure wrong-url "$fixture"
fixture="$(copy_case untrusted-effective-host)"; YEET_TEST_EFFECTIVE_URL="https://downloads.example.invalid/firecracker" assert_failure untrusted-effective-host "$fixture"
fixture="$(copy_case oversized-stream)"; : >"$curl_log"; YEET_TEST_OVERSIZED_ASSET=runtime-manifest.json assert_failure oversized-stream "$fixture"; grep -Eq '^bounded runtime-manifest[.]json at [1-9][0-9]* bytes$' "$curl_log" || fail "oversized stream did not exercise the bounded download"
fixture="$(copy_case malformed-manifest)"; printf '{ malformed\n' >"$fixture/assets/runtime-manifest.json"; update_asset_metadata "$fixture" runtime-manifest.json; assert_failure malformed-manifest "$fixture"
fixture="$(copy_case cross-field-invalid-manifest)"; jq '.upstream.version="v1.16.2"' "$fixture/assets/runtime-manifest.json" >"$fixture/m"; mv "$fixture/m" "$fixture/assets/runtime-manifest.json"; "$schema_validator" --schemafile "$manifest_schema" "$fixture/assets/runtime-manifest.json" >/dev/null || fail "cross-field fixture is not schema-valid"; (cd "$fixture/assets" && sha256sum firecracker jailer runtime-manifest.json >runtime-checksums.txt); update_asset_metadata "$fixture" runtime-manifest.json; update_asset_metadata "$fixture" runtime-checksums.txt; assert_failure cross-field-invalid-manifest "$fixture"
fixture="$(copy_case wrong-tag-target)"; jq '.object.sha="ffffffffffffffffffffffffffffffffffffffff"' "$fixture/tag-object.json" >"$fixture/t"; mv "$fixture/t" "$fixture/tag-object.json"; assert_failure wrong-tag-target "$fixture"

: >"$gh_log"
if YEET_TEST_PUBLISHED_FIXTURE="$base" YEET_TEST_PUBLISHED_GH_LOG="$gh_log" YEET_TEST_PUBLISHED_CURL_LOG="$curl_log" GH_TOKEN=test-token \
	GITHUB_ACTIONS=true GITHUB_REPOSITORY=yeetrun/yeet-vm-images CHECK_JSONSCHEMA="$schema_validator" \
	PATH="$tmp_dir/bin:$PATH" "$verifier" "$runtime_id" >/dev/null 2>&1; then
	fail "test fixture was accepted without explicit test mode"
fi
[ ! -s "$gh_log" ] || fail "test mock was called outside explicit test mode"

echo "Published Firecracker runtime verification fixtures passed"
