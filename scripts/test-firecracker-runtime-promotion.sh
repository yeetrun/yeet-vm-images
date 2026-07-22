#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
promoter="$repo_root/scripts/promote-firecracker-runtime.sh"
schema_validator="${CHECK_JSONSCHEMA:-$(command -v check-jsonschema || true)}"
if [ -z "$schema_validator" ] && command -v mise >/dev/null 2>&1; then schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"; fi
[ -n "$schema_validator" ] && [ -x "$schema_validator" ] || { echo "missing check-jsonschema" >&2; exit 1; }
[ -x "$promoter" ] || { echo "missing executable scripts/promote-firecracker-runtime.sh" >&2; exit 1; }
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "Firecracker runtime promotion test failed: $*" >&2; exit 1; }

runtime_id=firecracker-v1.16.1-yeet-v1
source_commit=89abcdef0123456789abcdef0123456789abcdef
yeet_commit=76543210fedcba9876543210fedcba9876543210
empty_catalog="$repo_root/scripts/testdata/runtime-catalog-empty.json"
fixtures="$tmp_dir/fixtures"; bin_dir="$tmp_dir/bin"; mkdir "$fixtures" "$bin_dir"
cp "$repo_root/scripts/testdata/runtime-manifest-v1.16.1.json" "$fixtures/runtime-manifest.json"
manifest_sha="$(sha256sum "$fixtures/runtime-manifest.json"|awk '{print $1}')"
jq --arg runtime "$runtime_id" --arg sha "$manifest_sha" --arg source "$source_commit" --arg yeet "$yeet_commit" '
  .subject={runtime_id:$runtime,manifest_sha256:$sha} |
  .source={repository:"yeetrun/yeet-vm-images",commit:$source,workflow_run:"123456789"} |
  .tested_yeet={repository:"yeetrun/yeet",commit:$yeet} |
  .artifacts={ubuntu_guest_release:"guest-ubuntu-26.04-amd64-v2",nixos_guest_release:"guest-nixos-26.05-amd64-v2",current_kernel_release:"kernel-linux-7.1.4-yeet-v4",previous_kernel_release:"kernel-linux-7.1.4-yeet-v3"}
' "$repo_root/scripts/testdata/runtime-attestation-integration.json" >"$fixtures/runtime-attestation.json"
attestation_sha="$(sha256sum "$fixtures/runtime-attestation.json"|awk '{print $1}')"
printf '%s  runtime-attestation.json\n' "$attestation_sha" >"$fixtures/runtime-attestation.sha256"

cat >"$bin_dir/verify-runtime" <<'MOCK_VERIFY'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = firecracker-v1.16.1-yeet-v1 ] || exit 90
path="$YEET_PROMOTION_FIXTURES/runtime-manifest.json"; size="$(wc -c <"$path"|tr -d ' ')"; sha="$(sha256sum "$path"|awk '{print $1}')"
[ "${YEET_PROMOTION_SCENARIO:-}" != manifest-metadata-digest ] || sha="$(printf '0%.0s' {1..64})"
jq -n --arg sha "$sha" --argjson size "$size" '{manifest_sha256:env.YEET_PROMOTION_MANIFEST_SHA,assets:[{id:401,name:"runtime-manifest.json",state:"uploaded",size:$size,digest:("sha256:"+$sha),url:"https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/401",browser_download_url:"https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.16.1-yeet-v1/runtime-manifest.json"}]}'
MOCK_VERIFY

cat >"$bin_dir/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 90; shift
scenario="${YEET_PROMOTION_SCENARIO:-success}" tag=firecracker-v1.16.1-yeet-v1-integration-123456789
if [ "$1" = "repos/yeetrun/yeet-vm-images/releases/tags/$tag" ]; then
	assets=""; id=500
	for name in runtime-attestation.json runtime-attestation.sha256; do
		id=$((id+1)); path="$YEET_PROMOTION_FIXTURES/$name"; size="$(wc -c <"$path"|tr -d ' ')"; digest="sha256:$(sha256sum "$path"|awk '{print $1}')"
		url="https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/$id"; browser="https://github.com/yeetrun/yeet-vm-images/releases/download/$tag/$name"
		[ "$scenario" != attestation-metadata-digest ] || { [ "$name" != runtime-attestation.json ] || digest="sha256:$(printf '0%.0s' {1..64})"; }
		[ "$scenario" != checksum-metadata-digest ] || { [ "$name" != runtime-attestation.sha256 ] || digest="sha256:$(printf '0%.0s' {1..64})"; }
		[ "$scenario" != wrong-asset-url ] || url="https://api.github.com/repos/other/repo/releases/assets/$id"
		assets="$assets$(jq -nc --argjson id "$id" --arg name "$name" --argjson size "$size" --arg digest "$digest" --arg url "$url" --arg browser "$browser" '{id:$id,name:$name,state:"uploaded",size:$size,digest:$digest,url:$url,browser_download_url:$browser}')
"
	done
	[ "$scenario" != extra-asset ] || assets="$assets$(jq -nc --arg tag "$tag" '{id:599,name:"extra",state:"uploaded",size:1,digest:("sha256:"+("0"*64)),url:"https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/599",browser_download_url:("https://github.com/yeetrun/yeet-vm-images/releases/download/"+$tag+"/extra")}')
"
	immutable=true; [ "$scenario" != mutable-release ] || immutable=false
	jq -n --arg tag "$tag" --argjson immutable "$immutable" --argjson assets "$(jq -sc . <<<"$assets")" '{tag_name:$tag,draft:false,prerelease:false,immutable:$immutable,published_at:"2026-07-19T20:00:00Z",assets:$assets}'
elif [ "$1" = "repos/yeetrun/yeet-vm-images/git/ref/tags/$tag" ]; then
	sha=89abcdef0123456789abcdef0123456789abcdef; [ "$scenario" != wrong-tag-target ] || sha=0000000000000000000000000000000000000000
	jq -n --arg sha "$sha" '{object:{type:"commit",sha:$sha}}'
else
	echo "unexpected promotion API query: $1" >&2; exit 91
fi
MOCK_GH

cat >"$bin_dir/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
output="" url="" write_out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) output="$2"; shift 2 ;;
		--write-out) write_out="$2"; shift 2 ;;
		--max-filesize|--max-time|--max-redirs|--connect-timeout|--proto|--proto-redir) shift 2 ;;
		--disable|--fail|--silent|--show-error|--location|--tlsv1.2) shift ;;
		*) url="$1"; shift ;;
	esac
done
[ -n "$output" ] && [ "$write_out" = '%{url_effective}' ] || exit 90
name="${url##*/}"; cp "$YEET_PROMOTION_FIXTURES/$name" "$output"
[ "${YEET_PROMOTION_SCENARIO:-}" != wrong-downloaded-size ] || printf extra >>"$output"
if [ "${YEET_PROMOTION_SCENARIO:-}" = unexpected-host ]; then printf 'https://example.invalid/%s' "$name"
else printf 'https://release-assets.githubusercontent.com/%s' "$name"; fi
MOCK_CURL
chmod +x "$bin_dir/verify-runtime" "$bin_dir/gh" "$bin_dir/curl"

stable_runtime='{
  "runtime_id": "firecracker-v1.15.0-yeet-v1",
  "manifest_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.15.0-yeet-v1/runtime-manifest.json",
  "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "upstream_version": "v1.15.0",
  "support": "supported",
  "integration_attestation_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.15.0-yeet-v1-integration-123456780/runtime-attestation.json",
  "integration_attestation_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "canary_attestation_url": "https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.15.0-yeet-v1-canary-123456781/runtime-attestation.json",
  "canary_attestation_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}'
catalog="$tmp_dir/catalog-with-stable.json"
jq --argjson stable "$stable_runtime" '
  .architectures.amd64.runtimes=[$stable] |
  .architectures.amd64.channels.stable={runtime_id:$stable.runtime_id,manifest_sha256:$stable.manifest_sha256}
' "$empty_catalog" >"$catalog"
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-catalog.schema.json" "$catalog" >/dev/null
"$repo_root/scripts/verify-runtime-catalog.sh" "$catalog"
jq -c '.architectures.amd64.channels.stable' "$catalog" >"$tmp_dir/stable-before.json"

promote() {
	local input="$1" output="$2" scenario="${3:-success}" attestation_url
	attestation_url="${4:-https://github.com/yeetrun/yeet-vm-images/releases/download/$runtime_id-integration-123456789/runtime-attestation.json}"
	YEET_RUNTIME_TEST_MODE=1 YEET_PROMOTION_SCENARIO="$scenario" YEET_PROMOTION_FIXTURES="$fixtures" \
		YEET_PROMOTION_MANIFEST_SHA="$manifest_sha" YEET_PROMOTION_VERIFY_RUNTIME="$bin_dir/verify-runtime" \
		PATH="$bin_dir:$PATH" CHECK_JSONSCHEMA="$schema_validator" \
		"$promoter" --channel candidate --runtime-id "$runtime_id" --manifest-sha256 "$manifest_sha" \
		--integration-attestation-url "$attestation_url" \
		--integration-attestation-sha256 "$attestation_sha" --catalog-in "$input" --catalog-out "$output"
}

output="$tmp_dir/promoted.json"; promote "$catalog" "$output"
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-catalog.schema.json" "$output" >/dev/null
"$repo_root/scripts/verify-runtime-catalog.sh" "$output"
jq -e --arg runtime "$runtime_id" --arg manifest "$manifest_sha" --arg attestation "$attestation_sha" '
  .architectures.amd64.channels.stable!=null and
  .architectures.amd64.channels.candidate=={runtime_id:$runtime,manifest_sha256:$manifest} and
  (.architectures.amd64.runtimes|length)==2 and
  ([.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)]|length)==1 and
  (.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)).manifest_sha256==$manifest and
  (.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)).integration_attestation_sha256==$attestation and
  (.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)).canary_attestation_url==null
' "$output" >/dev/null || fail "candidate catalog transition differs"
jq -c '.architectures.amd64.channels.stable' "$output" >"$tmp_dir/stable-after.json"
cmp -s "$tmp_dir/stable-before.json" "$tmp_dir/stable-after.json" || fail "candidate promotion changed the non-null stable pointer"
replay="$tmp_dir/replay.json"; promote "$output" "$replay"; cmp -s "$output" "$replay" || fail "exact candidate replay was not a no-op"
jq --arg runtime "$runtime_id" '(.architectures.amd64.runtimes[]|select(.runtime_id==$runtime)).integration_attestation_sha256=("0"*64)' "$output" >"$tmp_dir/conflict.json"
"$schema_validator" --schemafile "$repo_root/schemas/firecracker-runtime-catalog.schema.json" "$tmp_dir/conflict.json" >/dev/null || fail "same-subject evidence conflict fixture is not schema-valid"
"$repo_root/scripts/verify-runtime-catalog.sh" "$tmp_dir/conflict.json" || fail "same-subject evidence conflict fixture violates catalog invariants"
set +e
conflict_message="$(promote "$tmp_dir/conflict.json" "$tmp_dir/conflict-out.json" 2>&1)"
conflict_rc=$?
set -e
[ "$conflict_rc" -ne 0 ] || fail "conflicting catalog entry was accepted"
grep -Fq 'catalog already contains a conflicting runtime entry' <<<"$conflict_message" || fail "same-subject evidence conflict did not reach the promoter conflict check"
[ ! -e "$tmp_dir/conflict-out.json" ] || fail "same-subject evidence conflict wrote an output catalog"
if promote "$catalog" "$tmp_dir/rejected-lookalike-url.json" success \
	"https://githubXcom/yeetrun/yeet-vm-images/releases/download/$runtime_id-integration-123456789/runtime-attestation.json" >/dev/null 2>&1; then
	fail "promotion accepted a lookalike attestation URL"
fi

for scenario in manifest-metadata-digest mutable-release extra-asset wrong-asset-url attestation-metadata-digest checksum-metadata-digest wrong-downloaded-size unexpected-host wrong-tag-target; do
	if promote "$catalog" "$tmp_dir/rejected-$scenario.json" "$scenario" >/dev/null 2>&1; then fail "promotion accepted remote fixture: $scenario"; fi
done
cp "$fixtures/runtime-attestation.json" "$fixtures/runtime-attestation-baseline.json"
jq '.started_at="2026-07-19T14:37:00Z" | .completed_at="2026-07-19T14:00:00Z"' "$fixtures/runtime-attestation-baseline.json" >"$fixtures/runtime-attestation.json"
attestation_sha="$(sha256sum "$fixtures/runtime-attestation.json" | awk '{print $1}')"
printf '%s  runtime-attestation.json\n' "$attestation_sha" >"$fixtures/runtime-attestation.sha256"
if promote "$catalog" "$tmp_dir/rejected-time-order.json" >/dev/null 2>&1; then fail "promotion accepted evidence whose completion precedes its start"; fi
mv "$fixtures/runtime-attestation-baseline.json" "$fixtures/runtime-attestation.json"
attestation_sha="$(sha256sum "$fixtures/runtime-attestation.json" | awk '{print $1}')"
printf '%s  runtime-attestation.json\n' "$attestation_sha" >"$fixtures/runtime-attestation.sha256"
jq '.subject.manifest_sha256=("d"*64)' "$fixtures/runtime-attestation.json" >"$fixtures/a" && mv "$fixtures/a" "$fixtures/runtime-attestation.json"
if promote "$catalog" "$tmp_dir/rejected-subject.json" >/dev/null 2>&1; then fail "promotion accepted mismatched attestation subject"; fi

echo "Firecracker runtime candidate promotion verified"
