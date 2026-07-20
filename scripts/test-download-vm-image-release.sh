#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
downloader="$repo_root/scripts/download-vm-image-release.sh"
[ -x "$downloader" ] || { echo "missing executable VM image downloader" >&2; exit 1; }
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "VM image release download test failed: $*" >&2; exit 1; }

assets="$tmp_dir/assets"
mkdir "$assets" "$tmp_dir/bin"
for asset in rootfs.ext4.zst vmlinux firecracker jailer kernel.config; do printf 'verified %s fixture\n' "$asset" >"$assets/$asset"; done
jq -n --arg version ubuntu-26.04-amd64-kernel-7.1.4-v29 \
	--arg rootfs "$(sha256sum "$assets/rootfs.ext4.zst"|awk '{print $1}')" \
	--arg kernel "$(sha256sum "$assets/vmlinux"|awk '{print $1}')" \
	--arg firecracker "$(sha256sum "$assets/firecracker"|awk '{print $1}')" \
	--arg jailer "$(sha256sum "$assets/jailer"|awk '{print $1}')" \
	--arg config "$(sha256sum "$assets/kernel.config"|awk '{print $1}')" '
  {name:"yeet-ubuntu-26.04",version:$version,architecture:"x86_64",image_profile:"fast",
   kernel_policy:"yeet-managed",snap_support:false,guest_init:"/usr/local/lib/yeet-vm/yeet-init",
   guest_agent:"/usr/local/lib/yeet-vm/yeet-agent",kernel:"vmlinux",rootfs:"rootfs.ext4.zst",
   firecracker:"firecracker",jailer:"jailer",provenance:{yeet_rev:"76543210fedcba9876543210fedcba9876543210"},
   checksums:{"rootfs.ext4.zst":$rootfs,vmlinux:$kernel,firecracker:$firecracker,jailer:$jailer,"kernel.config":$config}}
' >"$assets/manifest.json"
(cd "$assets" && sha256sum manifest.json firecracker jailer kernel.config rootfs.ext4.zst vmlinux >checksums.txt)

cat >"$tmp_dir/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 90; shift
[ "$1" = "repos/yeetrun/yeet-vm-images/releases/tags/$YEET_GUEST_RELEASE" ] || exit 91
scenario="${YEET_GUEST_SCENARIO:-success}" tag="$YEET_GUEST_RELEASE"
records=""
id=100
for name in checksums.txt firecracker jailer kernel.config manifest.json rootfs.ext4.zst vmlinux; do
	id=$((id+1)); path="$YEET_GUEST_ASSETS/$name"; size="$(wc -c <"$path"|tr -d ' ')"; digest="sha256:$(sha256sum "$path"|awk '{print $1}')"
	url="https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/$id"
	browser="https://github.com/yeetrun/yeet-vm-images/releases/download/$tag/$name"
	[ "$scenario" != bad-api-url ] || url="https://api.github.com/repos/other/repo/releases/assets/$id"
	[ "$scenario" != bad-browser-url ] || browser="https://example.invalid/$name"
	[ "$scenario" != wrong-size ] || size=$((size+1))
	[ "$scenario" != wrong-digest ] || digest="sha256:$(printf '0%.0s' {1..64})"
	[ "$scenario" = missing-asset ] && [ "$name" = jailer ] && continue
	record="$(jq -nc --argjson id "$id" --arg name "$name" --argjson size "$size" --arg digest "$digest" --arg url "$url" --arg browser "$browser" '{id:$id,name:$name,state:"uploaded",size:$size,digest:$digest,url:$url,browser_download_url:$browser}')"
	records="$records$record
"
	[ "$scenario" != duplicate-asset ] || { [ "$name" != jailer ] || records="$records$record
"; }
done
if [ "$scenario" = extra-asset ]; then records="$records$(jq -nc --arg tag "$tag" '{id:999,name:"extra",state:"uploaded",size:1,digest:("sha256:"+("0"*64)),url:"https://api.github.com/repos/yeetrun/yeet-vm-images/releases/assets/999",browser_download_url:("https://github.com/yeetrun/yeet-vm-images/releases/download/"+$tag+"/extra")}' )
"; fi
immutable=true draft=false prerelease=false published='"2026-07-19T20:00:00Z"'
[ "$scenario" != mutable-release ] || immutable=false
jq -n --arg tag "$tag" --argjson assets "$(jq -sc . <<<"$records")" --argjson immutable "$immutable" --argjson draft "$draft" --argjson prerelease "$prerelease" --argjson published "$published" '{tag_name:$tag,draft:$draft,prerelease:$prerelease,immutable:$immutable,published_at:$published,assets:$assets}'
MOCK_GH

cat >"$tmp_dir/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
output="" url="" write_out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o|--output) output="$2"; shift 2 ;;
		--write-out) write_out="$2"; shift 2 ;;
		--max-filesize|--max-time|--max-redirs|--connect-timeout|--proto|--proto-redir) shift 2 ;;
		--disable|--fail|--silent|--show-error|--location|--tlsv1.2) shift ;;
		*) url="$1"; shift ;;
	esac
done
[ -n "$output" ] && [ -n "$url" ] && [ "$write_out" = '%{url_effective}' ] || exit 90
name="${url##*/}"; cp "$YEET_GUEST_ASSETS/$name" "$output"
[ "${YEET_GUEST_SCENARIO:-}" != oversized-stream ] || printf extra >>"$output"
if [ "${YEET_GUEST_SCENARIO:-}" = unexpected-host ]; then printf 'https://example.invalid/%s' "$name"
else printf 'https://release-assets.githubusercontent.com/%s' "$name"; fi
MOCK_CURL
chmod +x "$tmp_dir/bin/gh" "$tmp_dir/bin/curl"

run_download() {
	local scenario="$1" release="${2:-ubuntu-26.04-amd64-kernel-7.1.4-v29}" family="${3:-ubuntu}" out
	out="$tmp_dir/out-$scenario"
	YEET_GUEST_SCENARIO="$scenario" YEET_GUEST_RELEASE="$release" YEET_GUEST_ASSETS="$assets" \
		PATH="$tmp_dir/bin:$PATH" "$downloader" "$family" "$release" "$out"
}
run_download success
(cd "$tmp_dir/out-success" && sha256sum --check --strict checksums.txt >/dev/null) || fail "downloaded exact release checksums differ"
for scenario in mutable-release missing-asset extra-asset duplicate-asset bad-api-url bad-browser-url wrong-size wrong-digest oversized-stream unexpected-host; do
	if run_download "$scenario" >/dev/null 2>&1; then fail "downloader accepted fixture: $scenario"; fi
done

# Older immutable IDs without the kernel segment remain valid. The release
# manifest must still bind its exact tag.
jq '.version="ubuntu-24.04-amd64-v11" | .name="yeet-ubuntu-24.04"' "$assets/manifest.json" >"$assets/m" && mv "$assets/m" "$assets/manifest.json"
(cd "$assets" && sha256sum manifest.json firecracker jailer kernel.config rootfs.ext4.zst vmlinux >checksums.txt)
run_download legacy ubuntu-24.04-amd64-v11
if run_download alias ubuntu-24.04-amd64-latest >/dev/null 2>&1; then fail "downloader accepted a mutable alias"; fi

# The NixOS family follows the same immutable record and cross-field contract.
jq '.version="nixos-26.05-amd64-kernel-7.1.4-v29" | .name="yeet-nixos-26.05" | .image_profile="nixos"' "$assets/manifest.json" >"$assets/m" && mv "$assets/m" "$assets/manifest.json"
(cd "$assets" && sha256sum manifest.json firecracker jailer kernel.config rootfs.ext4.zst vmlinux >checksums.txt)
run_download nixos-success nixos-26.05-amd64-kernel-7.1.4-v29 nixos
jq '.version="ubuntu-26.04-amd64-kernel-7.1.4-v29"' "$assets/manifest.json" >"$assets/m" && mv "$assets/m" "$assets/manifest.json"
(cd "$assets" && sha256sum manifest.json firecracker jailer kernel.config rootfs.ext4.zst vmlinux >checksums.txt)
if run_download family-mismatch ubuntu-26.04-amd64-kernel-7.1.4-v29 ubuntu >/dev/null 2>&1; then fail "downloader accepted a guest family/manifest mismatch"; fi

jq '.version="ubuntu-26.04-amd64-kernel-7.1.4-v29" | .name="yeet-ubuntu-99.99" | .image_profile="fast"' "$assets/manifest.json" >"$assets/m" && mv "$assets/m" "$assets/manifest.json"
(cd "$assets" && sha256sum manifest.json firecracker jailer kernel.config rootfs.ext4.zst vmlinux >checksums.txt)
if run_download guest-version-mismatch ubuntu-26.04-amd64-kernel-7.1.4-v29 ubuntu >/dev/null 2>&1; then fail "downloader accepted a guest name/version mismatch"; fi

echo "Exact VM image release download verified"
