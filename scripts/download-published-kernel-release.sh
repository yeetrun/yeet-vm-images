#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 <exact-kernel-release-id> <out-dir>" >&2; exit 2; }
fail() { echo "Published kernel download failed: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
[ "$#" -eq 2 ] || usage
kernel_release="$1"
out_dir="$2"
repository="${GITHUB_REPOSITORY:-yeetrun/yeet-vm-images}"
[ "$repository" = yeetrun/yeet-vm-images ] || fail "unexpected repository"
if [[ ! "$kernel_release" =~ ^kernel-linux-([0-9]+[.][0-9]+([.][0-9]+)*)-yeet-v([1-9][0-9]*)$ ]]; then
	fail "release ID is not an exact immutable kernel release: $kernel_release"
fi
upstream_version="${BASH_REMATCH[1]}"
major_version="${upstream_version%%.*}"
expected_source_url="https://cdn.kernel.org/pub/linux/kernel/v${major_version}.x/linux-${upstream_version}.tar.xz"
[ ! -e "$out_dir" ] || fail "output path already exists"
for cmd in curl gh jq mkdir python3 sha256sum wc; do require "$cmd"; done

parent="$(dirname "$out_dir")"
mkdir -p "$parent"
tmp_dir="$(mktemp -d "$parent/.published-kernel.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM
assets_dir="$tmp_dir/assets"
release_json="$tmp_dir/release.json"
mkdir "$assets_dir"

gh api "repos/$repository/releases/tags/$kernel_release" >"$release_json"
jq -e --arg tag "$kernel_release" '
  .tag_name == $tag and .draft == false and .prerelease == false and
  .immutable == true and (.published_at | type == "string" and length > 0) and
  ([.assets[].name] | sort) == ["kernel-checksums.txt","kernel-manifest.json","kernel.config","vmlinux"] and
  ([.assets[].name] | length) == ([.assets[].name] | unique | length) and
  all(.assets[];
    (.id | type == "number" and . > 0 and floor == .) and
    .state == "uploaded" and
    (.size | type == "number" and . > 0 and . <= 268435456 and floor == .) and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    .url == ("https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/" + (.id | tostring)) and
    .browser_download_url == ("https://github.com/yeetrun/yeet-vm-images/releases/download/" + $tag + "/" + .name))
' "$release_json" >/dev/null || fail "release metadata is not immutable and exact"

asset_limit() {
	case "$1" in
		vmlinux) echo 268435456 ;;
		kernel.config|kernel-manifest.json|kernel-checksums.txt) echo 1048576 ;;
		*) return 1 ;;
	esac
}

download_asset() {
	local name="$1" destination record expected_size expected_digest browser_url limit effective_url final_host
	destination="$assets_dir/$name"
	record="$(jq -ce --arg name "$name" '[.assets[] | select(.name == $name)] | select(length == 1) | .[0]' "$release_json")" || fail "release is missing unique asset: $name"
	expected_size="$(jq -er '.size' <<<"$record")"
	expected_digest="$(jq -er '.digest | ltrimstr("sha256:")' <<<"$record")"
	browser_url="$(jq -er '.browser_download_url' <<<"$record")"
	limit="$(asset_limit "$name")" || fail "unexpected kernel asset: $name"
	[ "$expected_size" -le "$limit" ] || fail "published kernel asset exceeds size limit: $name"
	effective_url="$(curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--tlsv1.2 --connect-timeout 10 --max-time 900 --max-redirs 3 --max-filesize "$expected_size" \
		-o "$destination" --write-out '%{url_effective}' "$browser_url")" || fail "bounded kernel asset download failed: $name"
	final_host="$(python3 - "$effective_url" <<'PY'
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.argv[1])
if url.scheme != "https" or url.username is not None or url.password is not None or url.hostname is None or url.port not in (None, 443):
    raise SystemExit(1)
print(url.hostname)
PY
	)" || fail "kernel asset download ended at an invalid URL: $name"
	case "$final_host" in
		github.com|objects.githubusercontent.com|release-assets.githubusercontent.com) ;;
		*) fail "kernel asset download ended at an unexpected host: $name" ;;
	esac
	[ "$(wc -c <"$destination" | tr -d ' ')" = "$expected_size" ] || fail "downloaded kernel asset size mismatch: $name"
	[ "$(sha256sum "$destination" | awk '{print $1}')" = "$expected_digest" ] || fail "downloaded kernel asset digest mismatch: $name"
}

download_asset kernel-manifest.json
download_asset kernel-checksums.txt
download_asset vmlinux
download_asset kernel.config

manifest="$assets_dir/kernel-manifest.json"
jq -e --arg release "$kernel_release" --arg upstream "$upstream_version" --arg source "$expected_source_url" '
  keys == ["checksums","commit","kernel_build_fingerprint","kernel_config_url","kernel_source_sha256","kernel_source_url","kernel_version","localversion","release","repository","schema_version","upstream_kernel_version"] and
  .schema_version == 1 and .release == $release and
  .upstream_kernel_version == $upstream and .kernel_version == ("linux-" + $upstream + "-yeet") and
  .kernel_source_url == $source and (.kernel_source_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.kernel_config_url | type == "string" and test("^https://raw[.]githubusercontent[.]com/firecracker-microvm/firecracker/[0-9a-f]{40}/resources/guest_configs/microvm-kernel-ci-x86_64-6[.]1[.]config$")) and
  (.kernel_build_fingerprint | type == "string" and test("^[0-9a-f]{64}$")) and
  .localversion == "-yeet" and .repository == "yeetrun/yeet-vm-images" and
  (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.checksums | keys == ["kernel.config","vmlinux"]) and
  all(.checksums[]; type == "string" and test("^[0-9a-f]{64}$"))
' "$manifest" >/dev/null || fail "kernel manifest identity or lifecycle contract mismatch"

for binding in \
	"YEET_KERNEL_VERSION:upstream_kernel_version" \
	"YEET_KERNEL_SOURCE_URL:kernel_source_url" \
	"YEET_KERNEL_SOURCE_SHA256:kernel_source_sha256" \
	"YEET_KERNEL_CONFIG_URL:kernel_config_url" \
	"YEET_KERNEL_BUILD_FINGERPRINT:kernel_build_fingerprint"; do
	env_name="${binding%%:*}"
	field="${binding#*:}"
	expected="${!env_name:-}"
	if [ -n "$expected" ]; then
		actual="$(jq -er --arg field "$field" '.[$field]' "$manifest")"
		[ "$actual" = "$expected" ] || fail "kernel manifest $field mismatch: manifest=$actual expected=$expected"
	fi
done

for asset in vmlinux kernel.config; do
	want="$(jq -er --arg asset "$asset" '.checksums[$asset]' "$manifest")"
	got="$(sha256sum "$assets_dir/$asset" | awk '{print $1}')"
	[ "$got" = "$want" ] || fail "kernel manifest checksum mismatch: $asset"
done
expected_checksums="$(printf '%s  vmlinux\n%s  kernel.config' \
	"$(jq -er '.checksums.vmlinux' "$manifest")" \
	"$(jq -er '.checksums["kernel.config"]' "$manifest")")"
[ "$(cat "$assets_dir/kernel-checksums.txt")" = "$expected_checksums" ] || fail "kernel checksum file does not exactly bind the manifest payloads"
(cd "$assets_dir" && sha256sum --check --strict kernel-checksums.txt >/dev/null) || fail "kernel checksum verification failed"

chmod 0644 "$assets_dir/kernel-manifest.json" "$assets_dir/kernel-checksums.txt" "$assets_dir/vmlinux" "$assets_dir/kernel.config"
mv "$assets_dir" "$out_dir"
trap - EXIT INT TERM
rm -rf "$tmp_dir"
