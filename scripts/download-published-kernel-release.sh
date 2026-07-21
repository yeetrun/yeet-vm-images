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
jq -e --arg release "$kernel_release" --arg upstream "$upstream_version" '
  def sha256: type == "string" and test("^[0-9a-f]{64}$");
  keys == ["architecture","config","guest_packages","kernel_id","packaging_revision","provenance","schema_version","upstream_version","vmlinux"] and
  .schema_version == 1 and .kernel_id == $release and
  .upstream_version == $upstream and
  .kernel_id == "kernel-linux-\(.upstream_version)-yeet-v\(.packaging_revision)" and
  .architecture == "amd64" and
  .vmlinux.url == ("https://github.com/yeetrun/yeet-vm-images/releases/download/" + $release + "/vmlinux") and
  (.vmlinux.sha256 | sha256) and
  .config.url == ("https://github.com/yeetrun/yeet-vm-images/releases/download/" + $release + "/kernel.config") and
  (.config.sha256 | sha256) and
  .guest_packages == {
    catalog_url: "https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-packages/catalog.json",
    selector_schema_version: 2,
    release_id: $release
  } and
  (.provenance.source_commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.provenance.workflow_run_url | type == "string" and test("^https://github[.]com/yeetrun/yeet-vm-images/actions/runs/[1-9][0-9]*$"))
' "$manifest" >/dev/null || fail "kernel manifest identity or lifecycle contract mismatch"

expected_version="${YEET_KERNEL_VERSION:-}"
[ -z "$expected_version" ] || [ "$(jq -er '.upstream_version' "$manifest")" = "$expected_version" ] ||
	fail "kernel manifest upstream version mismatch"
manifest_sha256="$(sha256sum "$manifest" | awk '{print $1}')"
expected_manifest_sha256="${YEET_KERNEL_MANIFEST_SHA256:-}"
[ -z "$expected_manifest_sha256" ] || [ "$manifest_sha256" = "$expected_manifest_sha256" ] ||
	fail "kernel manifest SHA-256 mismatch"

for asset in vmlinux kernel.config; do
	case "$asset" in
		vmlinux) want="$(jq -er '.vmlinux.sha256' "$manifest")" ;;
		kernel.config) want="$(jq -er '.config.sha256' "$manifest")" ;;
	esac
	got="$(sha256sum "$assets_dir/$asset" | awk '{print $1}')"
	[ "$got" = "$want" ] || fail "kernel manifest checksum mismatch: $asset"
done
expected_checksums="$(printf '%s  vmlinux\n%s  kernel.config\n%s  kernel-manifest.json' \
	"$(jq -er '.vmlinux.sha256' "$manifest")" \
	"$(jq -er '.config.sha256' "$manifest")" \
	"$manifest_sha256")"
[ "$(cat "$assets_dir/kernel-checksums.txt")" = "$expected_checksums" ] || fail "kernel checksum file does not exactly bind the manifest payloads"
(cd "$assets_dir" && sha256sum --check --strict kernel-checksums.txt >/dev/null) || fail "kernel checksum verification failed"

chmod 0644 "$assets_dir/kernel-manifest.json" "$assets_dir/kernel-checksums.txt" "$assets_dir/vmlinux" "$assets_dir/kernel.config"
mv "$assets_dir" "$out_dir"
trap - EXIT INT TERM
rm -rf "$tmp_dir"
