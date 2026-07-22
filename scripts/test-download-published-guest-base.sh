#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
downloader="$repo_root/scripts/download-published-guest-base.sh"
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "Published guest-base download test failed: $*" >&2; exit 1; }

[ -x "$downloader" ] || fail "missing executable published guest-base downloader"

release=guest-ubuntu-26.04-amd64-v2
base_assets="$tmp_dir/base-assets"
bin_dir="$tmp_dir/bin"
mkdir "$base_assets" "$bin_dir"
printf 'verified guest rootfs fixture\n' >"$base_assets/rootfs.ext4.zst"
rootfs_sha="$(sha256sum "$base_assets/rootfs.ext4.zst" | awk '{print $1}')"
jq -n --arg release "$release" --arg rootfs "$rootfs_sha" '
  {
    schema_version: 1,
    guest_base_id: $release,
    os: "ubuntu",
    os_version: "26.04",
    architecture: "amd64",
    rootfs: {
      url: ("https://github.com/yeetrun/yeet-vm-images/releases/download/" + $release + "/rootfs.ext4.zst"),
      sha256: $rootfs,
      uncompressed_bytes: 2383413248
    },
    default_kernel_channel: "stable",
    provenance: {
      source_commit: "76543210fedcba9876543210fedcba9876543210",
      workflow_run_url: "https://github.com/yeetrun/yeet-vm-images/actions/runs/123456790"
    }
  }
' >"$base_assets/guest-manifest.json"
jq -n '{schema_version:1,builder:"fixture"}' >"$base_assets/provenance.json"
manifest_sha="$(sha256sum "$base_assets/guest-manifest.json" | awk '{print $1}')"
provenance_sha="$(sha256sum "$base_assets/provenance.json" | awk '{print $1}')"
printf '%s  rootfs.ext4.zst\n%s  guest-manifest.json\n%s  provenance.json\n' \
  "$rootfs_sha" "$manifest_sha" "$provenance_sha" >"$base_assets/checksums.txt"

cat >"$bin_dir/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 90
shift
[ "$1" = "repos/yeetrun/yeet-vm-images/releases/tags/$YEET_GUEST_BASE_RELEASE" ] || exit 91
scenario="${YEET_GUEST_BASE_SCENARIO:-success}"
records=""
id=800
for name in checksums.txt guest-manifest.json provenance.json rootfs.ext4.zst; do
  id=$((id + 1))
  [ "$scenario" = missing-asset ] && [ "$name" = provenance.json ] && continue
  path="$YEET_GUEST_BASE_ASSETS/$name"
  size="$(wc -c <"$path" | tr -d ' ')"
  digest="sha256:$(sha256sum "$path" | awk '{print $1}')"
  api_url="https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/$id"
  browser_url="https://github.com/yeetrun/yeet-vm-images/releases/download/$YEET_GUEST_BASE_RELEASE/$name"
  [ "$scenario" != bad-api-url ] || api_url="https://api.github.com/repos/other/repository/releases/assets/$id"
  [ "$scenario" != bad-browser-url ] || browser_url="https://example.invalid/$name"
  [ "$scenario" != wrong-size ] || { [ "$name" != rootfs.ext4.zst ] || size=$((size + 1)); }
  [ "$scenario" != oversized-metadata ] || { [ "$name" != guest-manifest.json ] || size=1048577; }
  [ "$scenario" != wrong-digest ] || { [ "$name" != rootfs.ext4.zst ] || digest="sha256:$(printf '0%.0s' {1..64})"; }
  record="$(jq -nc --argjson id "$id" --arg name "$name" --argjson size "$size" --arg digest "$digest" --arg url "$api_url" --arg browser "$browser_url" '{id:$id,name:$name,state:"uploaded",size:$size,digest:$digest,url:$url,browser_download_url:$browser}')"
  records="$records$record
"
  [ "$scenario" != duplicate-asset ] || { [ "$name" != provenance.json ] || records="$records$record
"; }
done
if [ "$scenario" = extra-asset ]; then
  records="$records$(jq -nc --arg tag "$YEET_GUEST_BASE_RELEASE" '{id:899,name:"extra",state:"uploaded",size:1,digest:("sha256:"+("0"*64)),url:"https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/899",browser_download_url:("https://github.com/yeetrun/yeet-vm-images/releases/download/"+$tag+"/extra")}')
"
fi
immutable=true
draft=false
prerelease=false
published='"2026-07-19T20:00:00Z"'
[ "$scenario" != mutable-release ] || immutable=false
[ "$scenario" != draft-release ] || draft=true
[ "$scenario" != prerelease ] || prerelease=true
[ "$scenario" != unpublished ] || published=null
jq -n --arg tag "$YEET_GUEST_BASE_RELEASE" --argjson immutable "$immutable" --argjson draft "$draft" \
  --argjson prerelease "$prerelease" --argjson published "$published" --argjson assets "$(jq -sc . <<<"$records")" \
  '{tag_name:$tag,draft:$draft,prerelease:$prerelease,immutable:$immutable,published_at:$published,assets:$assets}'
MOCK_GH

cat >"$bin_dir/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
output="" url="" write_out="" connect_timeout="" max_time="" max_redirs="" max_filesize="" proto="" proto_redir=""
disable=0 fail_flag=0 location=0 tls=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    --write-out) write_out="$2"; shift 2 ;;
    --connect-timeout) connect_timeout="$2"; shift 2 ;;
    --max-time) max_time="$2"; shift 2 ;;
    --max-redirs) max_redirs="$2"; shift 2 ;;
    --max-filesize) max_filesize="$2"; shift 2 ;;
    --proto) proto="$2"; shift 2 ;;
    --proto-redir) proto_redir="$2"; shift 2 ;;
    --disable) disable=1; shift ;;
    --fail) fail_flag=1; shift ;;
    --location) location=1; shift ;;
    --tlsv1.2) tls=1; shift ;;
    --silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "$output" ] && [ -n "$url" ] && [ "$write_out" = '%{url_effective}' ] || exit 90
name="${url##*/}"
[ "$disable" = 1 ] && [ "$fail_flag" = 1 ] && [ "$location" = 1 ] && [ "$tls" = 1 ] || exit 91
[ "$connect_timeout" = 10 ] && [ "$max_time" = 900 ] && [ "$max_redirs" = 3 ] || exit 92
[ "$proto" = '=https' ] && [ "$proto_redir" = '=https' ] || exit 93
[ "$max_filesize" = "$(wc -c <"$YEET_GUEST_BASE_ASSETS/$name" | tr -d ' ')" ] || {
  [ "${YEET_GUEST_BASE_SCENARIO:-}" = wrong-size ] || [ "${YEET_GUEST_BASE_SCENARIO:-}" = oversized-metadata ]
} || exit 94
cp "$YEET_GUEST_BASE_ASSETS/$name" "$output"
[ "${YEET_GUEST_BASE_SCENARIO:-}" != oversized-stream ] || { [ "$name" != rootfs.ext4.zst ] || printf extra >>"$output"; }
if [ "${YEET_GUEST_BASE_SCENARIO:-}" = unexpected-host ]; then
  printf 'https://example.invalid/%s' "$name"
else
  printf 'https://release-assets.githubusercontent.com/%s' "$name"
fi
MOCK_CURL
chmod +x "$bin_dir/gh" "$bin_dir/curl"

prepare_assets() {
  local scenario="$1" assets
  assets="$tmp_dir/assets-$scenario"
  cp -R "$base_assets" "$assets"
  case "$scenario" in
    manifest-release) jq '.guest_base_id="guest-ubuntu-26.04-amd64-v3"' "$assets/guest-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/guest-manifest.json" ;;
    manifest-os) jq '.os="nixos"' "$assets/guest-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/guest-manifest.json" ;;
    manifest-version) jq '.os_version="26.05"' "$assets/guest-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/guest-manifest.json" ;;
    manifest-architecture) jq '.architecture="arm64"' "$assets/guest-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/guest-manifest.json" ;;
    manifest-url) jq '.rootfs.url="https://example.invalid/rootfs.ext4.zst"' "$assets/guest-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/guest-manifest.json" ;;
    manifest-rootfs-digest) jq '.rootfs.sha256=("0"*64)' "$assets/guest-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/guest-manifest.json" ;;
    manifest-fields) jq '.provenance.source_commit="short"' "$assets/guest-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/guest-manifest.json" ;;
    checksum-file-mismatch) printf '%s  rootfs.ext4.zst\n' "$(printf '0%.0s' {1..64})" >"$assets/checksums.txt" ;;
    checksum-file-extra) printf '%s  extra\n' "$(printf '0%.0s' {1..64})" >>"$assets/checksums.txt" ;;
  esac
  printf '%s\n' "$assets"
}

run_download() {
  local scenario="$1" out assets
  out="$tmp_dir/out-$scenario"
  assets="$(prepare_assets "$scenario")"
  YEET_GUEST_BASE_SCENARIO="$scenario" YEET_GUEST_BASE_ASSETS="$assets" YEET_GUEST_BASE_RELEASE="$release" \
    GITHUB_REPOSITORY=yeetrun/yeet-vm-images PATH="$bin_dir:$PATH" "$downloader" "$release" "$out"
}

run_download success
expected=$'checksums.txt\nguest-manifest.json\nprovenance.json\nrootfs.ext4.zst'
actual="$(cd "$tmp_dir/out-success" && printf '%s\n' * | LC_ALL=C sort)"
[ "$actual" = "$expected" ] || fail "downloaded guest-base asset set differs"
(cd "$tmp_dir/out-success" && sha256sum --check --strict checksums.txt >/dev/null) || fail "downloaded checksum file does not verify"

for scenario in mutable-release draft-release prerelease unpublished missing-asset extra-asset duplicate-asset \
  bad-api-url bad-browser-url wrong-size oversized-metadata wrong-digest oversized-stream unexpected-host \
  manifest-release manifest-os manifest-version manifest-architecture manifest-url manifest-rootfs-digest manifest-fields \
  checksum-file-mismatch checksum-file-extra; do
  if run_download "$scenario" >/dev/null 2>&1; then fail "published guest-base downloader accepted fixture: $scenario"; fi
  [ ! -e "$tmp_dir/out-$scenario" ] || fail "failed published guest-base download left an output directory: $scenario"
done

if YEET_GUEST_BASE_SCENARIO=success YEET_GUEST_BASE_ASSETS="$base_assets" YEET_GUEST_BASE_RELEASE="$release" \
  GITHUB_REPOSITORY=other/repository PATH="$bin_dir:$PATH" "$downloader" "$release" "$tmp_dir/out-other-repo" >/dev/null 2>&1; then
  fail "published guest-base downloader accepted another repository"
fi
if run_download success >/dev/null 2>&1; then fail "published guest-base downloader overwrote an existing output"; fi

echo "Exact published guest-base download verified"
