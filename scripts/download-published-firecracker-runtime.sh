#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 <runtime-id> <manifest-sha256> <out-dir>" >&2; exit 2; }
fail() { echo "Published Firecracker runtime download failed: $*" >&2; exit 1; }
[ "$#" -eq 3 ] || usage
runtime_id="$1" manifest_sha256="$2" out_dir="$3"
[[ "$runtime_id" =~ ^firecracker-v[0-9]+[.][0-9]+[.][0-9]+-yeet-v[1-9][0-9]*$ ]] || fail "invalid runtime ID"
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "invalid manifest digest"
[ ! -e "$out_dir" ] || fail "output path already exists"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_verifier="${YEET_DOWNLOAD_RUNTIME_VERIFIER:-$repo_root/scripts/verify-published-firecracker-runtime.sh}"
if [ "$runtime_verifier" != "$repo_root/scripts/verify-published-firecracker-runtime.sh" ] && [ "${YEET_RUNTIME_TEST_MODE:-}" != 1 ]; then
	fail "runtime verifier override requires explicit test mode"
fi
[ -x "$runtime_verifier" ] || fail "runtime verifier is unavailable"
verification="$("$runtime_verifier" "$runtime_id")"
[ "$(jq -er '.manifest_sha256' <<<"$verification")" = "$manifest_sha256" ] || fail "published manifest digest differs from requested digest"
mkdir -p "$out_dir"
cleanup() { if [ "$?" -ne 0 ]; then rm -rf "$out_dir"; fi; }
trap cleanup EXIT INT TERM
base="https://github.com/yeetrun/yeet-vm-images/releases/download/$runtime_id"
for asset in firecracker jailer runtime-manifest.json runtime-checksums.txt; do
	record="$(jq -ce --arg name "$asset" '.assets[]|select(.name==$name)' <<<"$verification")" || fail "verified runtime metadata omitted asset: $asset"
	expected_size="$(jq -er '.size' <<<"$record")"; expected_digest="$(jq -er '.digest|ltrimstr("sha256:")' <<<"$record")"
	browser_url="$(jq -er '.browser_download_url' <<<"$record")"; [ "$browser_url" = "$base/$asset" ] || fail "verified runtime browser URL mismatch: $asset"
	effective_url="$(curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--tlsv1.2 --connect-timeout 10 --max-time 300 --max-redirs 3 --max-filesize "$expected_size" \
		-o "$out_dir/$asset" --write-out '%{url_effective}' "$browser_url")" || fail "bounded runtime asset download failed: $asset"
	final_host="$(python3 - "$effective_url" <<'PY'
import sys
from urllib.parse import urlsplit
url = urlsplit(sys.argv[1])
if url.scheme != "https" or url.username is not None or url.password is not None or url.hostname is None or url.port not in (None, 443):
    raise SystemExit(1)
print(url.hostname)
PY
	)" || fail "runtime asset download ended at an invalid URL: $asset"
	case "$final_host" in github.com|objects.githubusercontent.com|release-assets.githubusercontent.com) ;; *) fail "runtime asset download ended at an unexpected host: $asset" ;; esac
	[ "$(wc -c <"$out_dir/$asset" | tr -d ' ')" = "$expected_size" ] || fail "runtime asset size mismatch: $asset"
	[ "$(sha256sum "$out_dir/$asset" | awk '{print $1}')" = "$expected_digest" ] || fail "runtime asset digest mismatch: $asset"
done
chmod 0755 "$out_dir/firecracker" "$out_dir/jailer"
chmod 0644 "$out_dir/runtime-manifest.json" "$out_dir/runtime-checksums.txt"
[ "$(sha256sum "$out_dir/runtime-manifest.json" | awk '{print $1}')" = "$manifest_sha256" ] || fail "downloaded manifest digest mismatch"
(cd "$out_dir" && sha256sum --check --strict runtime-checksums.txt >/dev/null)
manifest_commit="$(jq -er '.provenance.commit' "$out_dir/runtime-manifest.json")"
"$repo_root/scripts/verify-firecracker-runtime-bundle.py" "$out_dir" "$runtime_id" "$manifest_commit" \
	"$repo_root/security/firecracker-runtime-policy.json" "$repo_root/scripts/resolve-firecracker-runtime-policy.py"
