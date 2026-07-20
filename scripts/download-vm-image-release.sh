#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 <ubuntu|nixos> <exact-release-id> <out-dir>" >&2; exit 2; }
fail() { echo "VM image release download failed: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
[ "$#" -eq 3 ] || usage
family="$1" release_id="$2" out_dir="$3"
repository="${GITHUB_REPOSITORY:-yeetrun/yeet-vm-images}"
[ "$repository" = yeetrun/yeet-vm-images ] || fail "unexpected repository"
case "$family" in
	ubuntu) pattern='^ubuntu-[0-9]+[.][0-9]+-amd64-(kernel-[0-9]+[.][0-9]+([.][0-9]+)*-)?v[1-9][0-9]*$' ;;
	nixos) pattern='^nixos-[0-9]+[.][0-9]+-amd64-(kernel-[0-9]+[.][0-9]+([.][0-9]+)*-)?v[1-9][0-9]*$' ;;
	*) usage ;;
esac
[[ "$release_id" =~ $pattern ]] || fail "release ID is not an exact immutable $family release: $release_id"
guest_version="${release_id#"$family-"}"
guest_version="${guest_version%%-amd64-*}"
expected_name="yeet-$family-$guest_version"
for cmd in curl gh jq mkdir python3 sha256sum; do require "$cmd"; done
[ ! -e "$out_dir" ] || fail "output path already exists"

parent="$(dirname "$out_dir")"
mkdir -p "$parent"
tmp_dir="$(mktemp -d "$parent/.vm-image-release.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM

release_json="$tmp_dir/release.json"
gh api "repos/$repository/releases/tags/$release_id" >"$release_json"
jq -e --arg tag "$release_id" '
  .tag_name == $tag and .draft == false and .prerelease == false and
  .immutable == true and (.published_at | type == "string" and length > 0) and
  (.assets | type == "array" and length > 0) and
  ([.assets[].name] | length == (unique | length)) and
  all(.assets[];
    (.id | type == "number" and . > 0 and floor == .) and .state == "uploaded" and (.size | type == "number" and . > 0 and . <= 8589934592) and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    .url == ("https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/" + (.id | tostring)) and
    .browser_download_url == ("https://github.com/yeetrun/yeet-vm-images/releases/download/" + $tag + "/" + .name))
' "$release_json" >/dev/null || fail "release metadata is not immutable and exact"

download_asset() {
	local name="$1" destination expected_size expected_digest browser_url effective_url final_host
	destination="$tmp_dir/assets/$name"
	mkdir -p "$(dirname "$destination")"
	expected_size="$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .size' "$release_json")" || fail "release is missing asset: $name"
	expected_digest="$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .digest | ltrimstr("sha256:")' "$release_json")" || fail "release is missing digest: $name"
	browser_url="https://github.com/$repository/releases/download/$release_id/$name"
	effective_url="$(curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--tlsv1.2 --connect-timeout 10 --max-time 900 --max-redirs 3 --max-filesize "$expected_size" \
		-o "$destination" --write-out '%{url_effective}' "$browser_url")" || fail "bounded asset download failed: $name"
	final_host="$(python3 - "$effective_url" <<'PY'
import sys
from urllib.parse import urlsplit
url = urlsplit(sys.argv[1])
if url.scheme != "https" or url.username is not None or url.password is not None or url.hostname is None or url.port not in (None, 443):
    raise SystemExit(1)
print(url.hostname)
PY
	)" || fail "asset download ended at an invalid URL: $name"
	case "$final_host" in github.com|objects.githubusercontent.com|release-assets.githubusercontent.com) ;; *) fail "asset download ended at an unexpected host: $name" ;; esac
	[ "$(wc -c <"$destination" | tr -d ' ')" = "$expected_size" ] || fail "downloaded size mismatch: $name"
	[ "$(sha256sum "$destination" | awk '{print $1}')" = "$expected_digest" ] || fail "downloaded digest mismatch: $name"
}

mkdir "$tmp_dir/assets"
download_asset manifest.json
download_asset checksums.txt
jq -e --arg family "$family" --arg release "$release_id" --arg expected_name "$expected_name" '
  .version == $release and .name == $expected_name and .architecture == "x86_64" and
  .image_profile == (if $family == "ubuntu" then "fast" else "nixos" end) and
  .kernel_policy == "yeet-managed" and
  .snap_support == false and (.initrd | not) and
  .rootfs == "rootfs.ext4.zst" and .kernel == "vmlinux" and
  .firecracker == "firecracker" and .jailer == "jailer" and
  (.provenance.yeet_rev | type == "string" and test("^[0-9a-f]{40}$")) and
  (.checksums | type == "object") and
  (.checksums | has("rootfs.ext4.zst") and has("vmlinux") and has("firecracker") and has("jailer"))
' "$tmp_dir/assets/manifest.json" >/dev/null || fail "guest manifest identity or lifecycle contract mismatch"

mapfile -t manifest_assets < <(jq -r '.checksums | keys[]' "$tmp_dir/assets/manifest.json" | LC_ALL=C sort)
expected_names=(checksums.txt manifest.json "${manifest_assets[@]}")
mapfile -t expected_names < <(printf '%s\n' "${expected_names[@]}" | LC_ALL=C sort -u)
mapfile -t actual_names < <(jq -r '.assets[].name' "$release_json" | LC_ALL=C sort)
[ "$(printf '%s\n' "${expected_names[@]}")" = "$(printf '%s\n' "${actual_names[@]}")" ] || fail "release asset set does not exactly match its manifest"
for asset in "${manifest_assets[@]}"; do
	[[ "$asset" != */* && "$asset" != .* && "$asset" != *..* ]] || fail "unsafe manifest asset name"
	download_asset "$asset"
done

(
	cd "$tmp_dir/assets"
	sha256sum --check --strict checksums.txt >/dev/null
)
for asset in "${manifest_assets[@]}"; do
	want="$(jq -er --arg asset "$asset" '.checksums[$asset] | select(test("^[0-9a-f]{64}$"))' "$tmp_dir/assets/manifest.json")"
	got="$(sha256sum "$tmp_dir/assets/$asset" | awk '{print $1}')"
	[ "$got" = "$want" ] || fail "manifest checksum mismatch: $asset"
done
mv "$tmp_dir/assets" "$out_dir"
trap - EXIT INT TERM
rm -rf "$tmp_dir"
