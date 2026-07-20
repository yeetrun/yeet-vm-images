#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
downloader="$repo_root/scripts/download-published-firecracker-runtime.sh"
[ -x "$downloader" ] || { echo "missing published runtime downloader" >&2; exit 1; }
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "Published runtime download test failed: $*" >&2; exit 1; }
assets="$tmp_dir/assets"; bin_dir="$tmp_dir/bin"; mkdir "$assets" "$bin_dir" "$tmp_dir/extract"
tar -xzf "$repo_root/scripts/testdata/firecracker-v1.16.1-x86_64.tgz" -C "$tmp_dir/extract"
cp "$tmp_dir/extract/release-v1.16.1-x86_64/firecracker-v1.16.1-x86_64" "$assets/firecracker"
cp "$tmp_dir/extract/release-v1.16.1-x86_64/jailer-v1.16.1-x86_64" "$assets/jailer"
jq --arg firecracker "$(sha256sum "$assets/firecracker"|awk '{print $1}')" --arg jailer "$(sha256sum "$assets/jailer"|awk '{print $1}')" '
  .components.firecracker.sha256=$firecracker | .components.jailer.sha256=$jailer
' "$repo_root/scripts/testdata/runtime-manifest-v1.16.1.json" >"$assets/runtime-manifest.json"
chmod 0755 "$assets/firecracker" "$assets/jailer"; chmod 0644 "$assets/runtime-manifest.json"
(cd "$assets" && sha256sum firecracker jailer runtime-manifest.json >runtime-checksums.txt && chmod 0644 runtime-checksums.txt)
manifest_sha="$(sha256sum "$assets/runtime-manifest.json"|awk '{print $1}')"

cat >"$bin_dir/verify-runtime" <<'MOCK_VERIFY'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = firecracker-v1.16.1-yeet-v1 ] || exit 90
records=""; id=400
for name in firecracker jailer runtime-manifest.json runtime-checksums.txt; do
	id=$((id+1)); path="$YEET_RUNTIME_DOWNLOAD_ASSETS/$name"; size="$(wc -c <"$path"|tr -d ' ')"; digest="sha256:$(sha256sum "$path"|awk '{print $1}')"
	[ "${YEET_RUNTIME_DOWNLOAD_SCENARIO:-}" != bad-metadata-digest ] || { [ "$name" != jailer ] || digest="sha256:$(printf '0%.0s' {1..64})"; }
	url="https://github.com/yeetrun/yeet-vm-images/releases/download/firecracker-v1.16.1-yeet-v1/$name"
	[ "${YEET_RUNTIME_DOWNLOAD_SCENARIO:-}" != bad-browser-url ] || { [ "$name" != jailer ] || url="https://example.invalid/jailer"; }
	records="$records$(jq -nc --argjson id "$id" --arg name "$name" --argjson size "$size" --arg digest "$digest" --arg url "$url" '{id:$id,name:$name,state:"uploaded",size:$size,digest:$digest,url:("https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/"+($id|tostring)),browser_download_url:$url}')
"
done
manifest_sha="$YEET_RUNTIME_DOWNLOAD_MANIFEST_SHA"; [ "${YEET_RUNTIME_DOWNLOAD_SCENARIO:-}" != wrong-manifest-subject ] || manifest_sha="$(printf '0%.0s' {1..64})"
jq -n --arg sha "$manifest_sha" --argjson assets "$(jq -sc . <<<"$records")" '{manifest_sha256:$sha,assets:$assets}'
MOCK_VERIFY
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
name="${url##*/}"; cp "$YEET_RUNTIME_DOWNLOAD_ASSETS/$name" "$output"
[ "${YEET_RUNTIME_DOWNLOAD_SCENARIO:-}" != wrong-size ] || { [ "$name" != jailer ] || printf extra >>"$output"; }
if [ "${YEET_RUNTIME_DOWNLOAD_SCENARIO:-}" = unexpected-host ]; then printf 'https://example.invalid/%s' "$name"
else printf 'https://release-assets.githubusercontent.com/%s' "$name"; fi
MOCK_CURL
chmod +x "$bin_dir/verify-runtime" "$bin_dir/curl"

run_download() {
	local scenario="$1" out
	out="$tmp_dir/out-$scenario"
	YEET_RUNTIME_TEST_MODE=1 YEET_RUNTIME_DOWNLOAD_SCENARIO="$scenario" YEET_RUNTIME_DOWNLOAD_ASSETS="$assets" \
		YEET_RUNTIME_DOWNLOAD_MANIFEST_SHA="$manifest_sha" YEET_DOWNLOAD_RUNTIME_VERIFIER="$bin_dir/verify-runtime" \
		PATH="$bin_dir:$PATH" "$downloader" firecracker-v1.16.1-yeet-v1 "$manifest_sha" "$out"
}
run_download success
(cd "$tmp_dir/out-success" && sha256sum --check --strict runtime-checksums.txt >/dev/null) || fail "downloaded runtime checksum verification failed"
for scenario in bad-metadata-digest bad-browser-url wrong-manifest-subject wrong-size unexpected-host; do
	if run_download "$scenario" >/dev/null 2>&1; then fail "runtime downloader accepted fixture: $scenario"; fi
done
if YEET_DOWNLOAD_RUNTIME_VERIFIER="$bin_dir/verify-runtime" PATH="$bin_dir:$PATH" "$downloader" firecracker-v1.16.1-yeet-v1 "$manifest_sha" "$tmp_dir/out-no-test-mode" >/dev/null 2>&1; then
	fail "runtime verifier injection was accepted outside explicit test mode"
fi
echo "Exact published runtime download verified"
