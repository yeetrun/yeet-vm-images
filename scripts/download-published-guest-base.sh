#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 <exact-guest-base-id> <out-dir>" >&2; exit 2; }
fail() { echo "Published guest-base download failed: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

[ "$#" -eq 2 ] || usage
guest_base_id="$1"
out_dir="$2"
repository="${GITHUB_REPOSITORY:-yeetrun/yeet-vm-images}"
[ "$repository" = yeetrun/yeet-vm-images ] || fail "unexpected repository"
if [[ ! "$guest_base_id" =~ ^guest-(ubuntu|nixos)-([0-9]+[.][0-9]+)-amd64-v([1-9][0-9]*)$ ]]; then
	fail "release ID is not an exact immutable guest-base release: $guest_base_id"
fi
guest_os="${BASH_REMATCH[1]}"
os_version="${BASH_REMATCH[2]}"
[ ! -e "$out_dir" ] || fail "output path already exists"
for cmd in curl gh jq mkdir python3 sha256sum wc; do require "$cmd"; done

parent="$(dirname "$out_dir")"
mkdir -p "$parent"
tmp_dir="$(mktemp -d "$parent/.published-guest-base.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM
assets_dir="$tmp_dir/assets"
release_json="$tmp_dir/release.json"
mkdir "$assets_dir"

gh api "repos/$repository/releases/tags/$guest_base_id" >"$release_json"
jq -e --arg tag "$guest_base_id" '
  .tag_name == $tag and .draft == false and .prerelease == false and
  .immutable == true and (.published_at | type == "string" and length > 0) and
  ([.assets[].name] | sort) == ["checksums.txt","guest-manifest.json","provenance.json","rootfs.ext4.zst"] and
  ([.assets[].name] | length) == ([.assets[].name] | unique | length) and
  all(.assets[];
    (.id | type == "number" and . > 0 and floor == .) and
    .state == "uploaded" and
    (.size | type == "number" and . > 0 and . <= 8589934592 and floor == .) and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    .url == ("https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/" + (.id | tostring)) and
    .browser_download_url == ("https://github.com/yeetrun/yeet-vm-images/releases/download/" + $tag + "/" + .name))
' "$release_json" >/dev/null || fail "release metadata is not immutable and exact"

asset_limit() {
	case "$1" in
		rootfs.ext4.zst) echo 8589934592 ;;
		checksums.txt|guest-manifest.json|provenance.json) echo 1048576 ;;
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
	limit="$(asset_limit "$name")" || fail "unexpected guest-base asset: $name"
	[ "$expected_size" -le "$limit" ] || fail "published guest-base asset exceeds size limit: $name"
	effective_url="$(curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--tlsv1.2 --connect-timeout 10 --max-time 900 --max-redirs 3 --max-filesize "$expected_size" \
		-o "$destination" --write-out '%{url_effective}' "$browser_url")" || fail "bounded guest-base asset download failed: $name"
	final_host="$(python3 - "$effective_url" <<'PY'
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.argv[1])
if url.scheme != "https" or url.username is not None or url.password is not None or url.hostname is None or url.port not in (None, 443):
    raise SystemExit(1)
print(url.hostname)
PY
	)" || fail "guest-base asset download ended at an invalid URL: $name"
	case "$final_host" in
		github.com|objects.githubusercontent.com|release-assets.githubusercontent.com) ;;
		*) fail "guest-base asset download ended at an unexpected host: $name" ;;
	esac
	[ "$(wc -c <"$destination" | tr -d ' ')" = "$expected_size" ] || fail "downloaded guest-base asset size mismatch: $name"
	[ "$(sha256sum "$destination" | awk '{print $1}')" = "$expected_digest" ] || fail "downloaded guest-base asset digest mismatch: $name"
}

download_asset guest-manifest.json
download_asset checksums.txt
download_asset provenance.json
download_asset rootfs.ext4.zst

manifest="$assets_dir/guest-manifest.json"
jq -e --arg id "$guest_base_id" --arg os "$guest_os" --arg version "$os_version" '
  def sha256: type == "string" and test("^[0-9a-f]{64}$");
  keys == ["architecture","default_kernel_channel","guest_base_id","os","os_version","provenance","rootfs","schema_version"] and
  .schema_version == 1 and .guest_base_id == $id and .os == $os and .os_version == $version and
  .architecture == "amd64" and
  (.rootfs | keys == ["sha256","uncompressed_bytes","url"]) and
  .rootfs.url == ("https://github.com/yeetrun/yeet-vm-images/releases/download/" + $id + "/rootfs.ext4.zst") and
  (.rootfs.sha256 | sha256) and
  (.rootfs.uncompressed_bytes | type == "number" and . > 0 and . <= 17179869184 and floor == .) and
  (.default_kernel_channel == "stable" or .default_kernel_channel == "candidate") and
  (.provenance | keys == ["source_commit","workflow_run_url"]) and
  (.provenance.source_commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.provenance.workflow_run_url | test("^https://github[.]com/yeetrun/yeet-vm-images/actions/runs/[1-9][0-9]*$"))
' "$manifest" >/dev/null || fail "guest-base manifest identity or lifecycle contract mismatch"

rootfs_sha="$(sha256sum "$assets_dir/rootfs.ext4.zst" | awk '{print $1}')"
[ "$rootfs_sha" = "$(jq -er '.rootfs.sha256' "$manifest")" ] || fail "guest-base manifest rootfs digest mismatch"
manifest_sha="$(sha256sum "$manifest" | awk '{print $1}')"
provenance_sha="$(sha256sum "$assets_dir/provenance.json" | awk '{print $1}')"
expected_checksums="$(printf '%s  rootfs.ext4.zst\n%s  guest-manifest.json\n%s  provenance.json' "$rootfs_sha" "$manifest_sha" "$provenance_sha")"
[ "$(cat "$assets_dir/checksums.txt")" = "$expected_checksums" ] || fail "guest-base checksum file does not exactly bind the release payloads"
(cd "$assets_dir" && sha256sum --check --strict checksums.txt >/dev/null) || fail "guest-base checksum verification failed"

chmod 0644 "$assets_dir/checksums.txt" "$assets_dir/guest-manifest.json" "$assets_dir/provenance.json" "$assets_dir/rootfs.ext4.zst"
mv "$assets_dir" "$out_dir"
trap - EXIT INT TERM
rm -rf "$tmp_dir"
