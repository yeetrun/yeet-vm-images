#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
downloader="$repo_root/scripts/download-published-kernel-release.sh"
[ -x "$downloader" ] || { echo "missing executable published kernel downloader" >&2; exit 1; }
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "Published kernel download test failed: $*" >&2; exit 1; }

release=kernel-linux-7.1.4-yeet-v1
base_assets="$tmp_dir/base-assets"
bin_dir="$tmp_dir/bin"
mkdir "$base_assets" "$bin_dir"
printf 'verified kernel payload\n' >"$base_assets/vmlinux"
printf 'verified kernel config\n' >"$base_assets/kernel.config"
vmlinux_sha="$(sha256sum "$base_assets/vmlinux" | awk '{print $1}')"
config_sha="$(sha256sum "$base_assets/kernel.config" | awk '{print $1}')"
jq -n \
	--arg release "$release" \
	--arg source_sha "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
	--arg build_sha "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" \
	--arg commit "76543210fedcba9876543210fedcba9876543210" \
	--arg vmlinux "$vmlinux_sha" --arg config "$config_sha" '
  {schema_version:1,release:$release,upstream_kernel_version:"7.1.4",kernel_version:"linux-7.1.4-yeet",
   kernel_source_url:"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.4.tar.xz",
   kernel_source_sha256:$source_sha,
   kernel_config_url:"https://raw.githubusercontent.com/firecracker-microvm/firecracker/86a2559b26a4b9a05405aeaa58bab0f7261d71bc/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config",
   kernel_build_fingerprint:$build_sha,localversion:"-yeet",repository:"yeetrun/yeet-vm-images",commit:$commit,
   checksums:{vmlinux:$vmlinux,"kernel.config":$config}}
' >"$base_assets/kernel-manifest.json"
printf '%s  vmlinux\n%s  kernel.config\n' "$vmlinux_sha" "$config_sha" >"$base_assets/kernel-checksums.txt"

cat >"$bin_dir/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 90
shift
[ "$1" = "repos/yeetrun/yeet-vm-images/releases/tags/$YEET_KERNEL_RELEASE" ] || exit 91
scenario="${YEET_KERNEL_DOWNLOAD_SCENARIO:-success}"
records=""
id=700
for name in kernel-checksums.txt kernel-manifest.json kernel.config vmlinux; do
	id=$((id + 1))
	[ "$scenario" = missing-asset ] && [ "$name" = kernel.config ] && continue
	path="$YEET_KERNEL_DOWNLOAD_ASSETS/$name"
	size="$(wc -c <"$path" | tr -d ' ')"
	digest="sha256:$(sha256sum "$path" | awk '{print $1}')"
	api_url="https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/$id"
	browser_url="https://github.com/yeetrun/yeet-vm-images/releases/download/$YEET_KERNEL_RELEASE/$name"
	[ "$scenario" != bad-api-url ] || api_url="https://api.github.com/repos/other/repository/releases/assets/$id"
	[ "$scenario" != bad-browser-url ] || browser_url="https://example.invalid/$name"
	[ "$scenario" != wrong-size ] || { [ "$name" != vmlinux ] || size=$((size + 1)); }
	[ "$scenario" != oversized-metadata ] || { [ "$name" != vmlinux ] || size=268435457; }
	[ "$scenario" != wrong-digest ] || { [ "$name" != vmlinux ] || digest="sha256:$(printf '0%.0s' {1..64})"; }
	record="$(jq -nc --argjson id "$id" --arg name "$name" --argjson size "$size" --arg digest "$digest" --arg url "$api_url" --arg browser "$browser_url" '{id:$id,name:$name,state:"uploaded",size:$size,digest:$digest,url:$url,browser_download_url:$browser}')"
	records="$records$record
"
	[ "$scenario" != duplicate-asset ] || { [ "$name" != kernel.config ] || records="$records$record
"; }
done
if [ "$scenario" = extra-asset ]; then
	records="$records$(jq -nc --arg tag "$YEET_KERNEL_RELEASE" '{id:799,name:"extra",state:"uploaded",size:1,digest:("sha256:"+("0"*64)),url:"https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/799",browser_download_url:("https://github.com/yeetrun/yeet-vm-images/releases/download/"+$tag+"/extra")}')
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
jq -n --arg tag "$YEET_KERNEL_RELEASE" --argjson immutable "$immutable" --argjson draft "$draft" \
	--argjson prerelease "$prerelease" --argjson published "$published" --argjson assets "$(jq -sc . <<<"$records")" \
	'{tag_name:$tag,draft:$draft,prerelease:$prerelease,immutable:$immutable,published_at:$published,assets:$assets}'
MOCK_GH

cat >"$bin_dir/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
write_out=""
connect_timeout=""
max_time=""
max_redirs=""
max_filesize=""
proto=""
proto_redir=""
disable=0
fail_flag=0
location=0
tls=0
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
[ "$max_filesize" = "$(wc -c <"$YEET_KERNEL_DOWNLOAD_ASSETS/$name" | tr -d ' ')" ] || {
	[ "${YEET_KERNEL_DOWNLOAD_SCENARIO:-}" = wrong-size ] || [ "${YEET_KERNEL_DOWNLOAD_SCENARIO:-}" = oversized-metadata ]
} || exit 94
cp "$YEET_KERNEL_DOWNLOAD_ASSETS/$name" "$output"
[ "${YEET_KERNEL_DOWNLOAD_SCENARIO:-}" != oversized-stream ] || { [ "$name" != vmlinux ] || printf extra >>"$output"; }
if [ "${YEET_KERNEL_DOWNLOAD_SCENARIO:-}" = unexpected-host ]; then
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
		manifest-release) jq '.release="kernel-linux-7.1.4-yeet-v2"' "$assets/kernel-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/kernel-manifest.json" ;;
		manifest-repository) jq '.repository="other/repository"' "$assets/kernel-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/kernel-manifest.json" ;;
		manifest-upstream) jq '.upstream_kernel_version="7.1.5"' "$assets/kernel-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/kernel-manifest.json" ;;
		manifest-fields) jq '.kernel_build_fingerprint="short"' "$assets/kernel-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/kernel-manifest.json" ;;
		manifest-missing-checksum) jq 'del(.checksums["kernel.config"])' "$assets/kernel-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/kernel-manifest.json" ;;
		manifest-wrong-checksum) jq '.checksums.vmlinux=("0"*64)' "$assets/kernel-manifest.json" >"$assets/m"; mv "$assets/m" "$assets/kernel-manifest.json" ;;
		checksum-file-mismatch) printf '%s  vmlinux\n%s  kernel.config\n' "$(printf '0%.0s' {1..64})" "$config_sha" >"$assets/kernel-checksums.txt" ;;
		checksum-file-extra) printf '%s  extra\n' "$(printf '0%.0s' {1..64})" >>"$assets/kernel-checksums.txt" ;;
	esac
	printf '%s\n' "$assets"
}

run_download() {
	local scenario="$1" out assets
	out="$tmp_dir/out-$scenario"
	assets="$(prepare_assets "$scenario")"
	YEET_KERNEL_DOWNLOAD_SCENARIO="$scenario" YEET_KERNEL_DOWNLOAD_ASSETS="$assets" YEET_KERNEL_RELEASE="$release" \
		GITHUB_REPOSITORY=yeetrun/yeet-vm-images \
		YEET_KERNEL_VERSION=7.1.4 \
		YEET_KERNEL_SOURCE_URL=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.4.tar.xz \
		YEET_KERNEL_SOURCE_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
		YEET_KERNEL_CONFIG_URL=https://raw.githubusercontent.com/firecracker-microvm/firecracker/86a2559b26a4b9a05405aeaa58bab0f7261d71bc/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config \
		YEET_KERNEL_BUILD_FINGERPRINT=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \
		PATH="$bin_dir:$PATH" "$downloader" "$release" "$out"
}

run_download success
expected=$'kernel-checksums.txt\nkernel-manifest.json\nkernel.config\nvmlinux'
actual="$(cd "$tmp_dir/out-success" && printf '%s\n' * | LC_ALL=C sort)"
[ "$actual" = "$expected" ] || fail "downloaded kernel asset set differs"
(cd "$tmp_dir/out-success" && sha256sum --check --strict kernel-checksums.txt >/dev/null) || fail "downloaded checksum file does not verify"

for scenario in mutable-release draft-release prerelease unpublished missing-asset extra-asset duplicate-asset \
	bad-api-url bad-browser-url wrong-size oversized-metadata wrong-digest oversized-stream unexpected-host \
	manifest-release manifest-repository manifest-upstream manifest-fields manifest-missing-checksum manifest-wrong-checksum \
	checksum-file-mismatch checksum-file-extra; do
	if run_download "$scenario" >/dev/null 2>&1; then fail "published kernel downloader accepted fixture: $scenario"; fi
	[ ! -e "$tmp_dir/out-$scenario" ] || fail "failed published kernel download left an output directory: $scenario"
done

if YEET_KERNEL_DOWNLOAD_SCENARIO=success YEET_KERNEL_DOWNLOAD_ASSETS="$base_assets" YEET_KERNEL_RELEASE="$release" \
	GITHUB_REPOSITORY=other/repository PATH="$bin_dir:$PATH" "$downloader" "$release" "$tmp_dir/out-other-repo" >/dev/null 2>&1; then
	fail "published kernel downloader accepted another repository"
fi
if run_download success >/dev/null 2>&1; then fail "published kernel downloader overwrote an existing output"; fi

echo "Exact published kernel download verified"
