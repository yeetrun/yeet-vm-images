#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

fake_bin="$tmp_dir/bin"
remote_dir="$tmp_dir/remote"
out_dir="$tmp_dir/out"
mkdir -p "$fake_bin" "$remote_dir" "$out_dir"

printf 'kernel payload\n' >"$remote_dir/vmlinux"
printf 'config payload\n' >"$remote_dir/kernel.config"
vmlinux_sha="$(sha256sum "$remote_dir/vmlinux" | awk '{ print $1 }')"
kernel_config_sha="$(sha256sum "$remote_dir/kernel.config" | awk '{ print $1 }')"
write_manifest() {
	local vmlinux_checksum="${1:-$vmlinux_sha}"
	local kernel_config_checksum="${2:-$kernel_config_sha}"
	local checksums_filter="${3:-.}"
	jq -n \
		--arg release "kernel-linux-7.1.1-yeet-v2" \
		--arg upstream_kernel_version "7.1.1" \
		--arg kernel_version "linux-7.1.1-yeet" \
		--arg kernel_source_url "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz" \
		--arg kernel_source_sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
		--arg kernel_config_url "https://example.invalid/kernel.config" \
		--arg vmlinux_sha "$vmlinux_checksum" \
		--arg kernel_config_sha "$kernel_config_checksum" \
		'{
		  schema_version: 1,
		  release: $release,
		  upstream_kernel_version: $upstream_kernel_version,
		  kernel_version: $kernel_version,
		  kernel_source_url: $kernel_source_url,
		  kernel_source_sha256: $kernel_source_sha256,
		  kernel_config_url: $kernel_config_url,
		  localversion: "-yeet",
		  repository: "yeetrun/yeet-vm-images",
		  commit: "abc123",
		  checksums: {
		    vmlinux: $vmlinux_sha,
		    "kernel.config": $kernel_config_sha
		  }
		}' | jq "$checksums_filter" >"$remote_dir/kernel-manifest.json"
}

run_download() {
	local output_dir="$1"
	shift
	PATH="$fake_bin:$PATH" \
		GITHUB_REPOSITORY=yeetrun/yeet-vm-images \
		YEET_TEST_REMOTE_DIR="$remote_dir" \
		YEET_KERNEL_VERSION=7.1.1 \
		YEET_KERNEL_SOURCE_URL=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.1.tar.xz \
		YEET_KERNEL_SOURCE_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
		YEET_KERNEL_CONFIG_URL=https://example.invalid/kernel.config \
		"$repo_root/scripts/download-kernel-release.sh" kernel-linux-7.1.1-yeet-v2 "$output_dir" "$@"
}

write_manifest

cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

out=""
url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o)
			out="$2"
			shift 2
			;;
		--retry)
			shift 2
			;;
		-*)
			shift
			;;
		*)
			url="$1"
			shift
			;;
	esac
done

if [ -z "$out" ] || [ -z "$url" ]; then
	echo "fake curl missing output or URL" >&2
	exit 1
fi
url_prefix="https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.1-yeet-v2/"
case "$url" in
	"$url_prefix"*) ;;
	*)
		echo "unexpected URL: $url" >&2
		exit 1
		;;
esac
asset="${url##*/}"
cp "$YEET_TEST_REMOTE_DIR/$asset" "$out"
FAKE_CURL
chmod +x "$fake_bin/curl"

run_download "$out_dir"

cmp "$remote_dir/vmlinux" "$out_dir/vmlinux"
cmp "$remote_dir/kernel.config" "$out_dir/kernel.config"
test -s "$out_dir/kernel-checksums.txt"
if ! grep -Eq "^[0-9a-f]{64}  vmlinux$" "$out_dir/kernel-checksums.txt"; then
	echo "checksum file missing relative vmlinux entry" >&2
	exit 1
fi
if ! grep -Eq "^[0-9a-f]{64}  kernel[.]config$" "$out_dir/kernel-checksums.txt"; then
	echo "checksum file missing relative kernel.config entry" >&2
	exit 1
fi
if grep -Fq "$out_dir" "$out_dir/kernel-checksums.txt"; then
	echo "checksum file contains output directory path" >&2
	exit 1
fi
if grep -Eq "^[0-9a-f]{64}  /" "$out_dir/kernel-checksums.txt"; then
	echo "checksum file contains an absolute path" >&2
	exit 1
fi

if PATH="$fake_bin:$PATH" \
	GITHUB_REPOSITORY=yeetrun/yeet-vm-images \
	YEET_TEST_REMOTE_DIR="$remote_dir" \
	YEET_KERNEL_VERSION=7.1.2 \
	"$repo_root/scripts/download-kernel-release.sh" kernel-linux-7.1.1-yeet-v2 "$tmp_dir/bad" >/dev/null 2>&1; then
	echo "download helper accepted mismatched kernel version" >&2
	exit 1
fi

write_manifest "0000000000000000000000000000000000000000000000000000000000000000"
if run_download "$tmp_dir/bad-vmlinux" >/dev/null 2>&1; then
	echo "download helper accepted bad vmlinux checksum" >&2
	exit 1
fi

write_manifest "$vmlinux_sha" "$kernel_config_sha" 'del(.checksums["kernel.config"])'
if run_download "$tmp_dir/missing-kernel-config-checksum" >/dev/null 2>&1; then
	echo "download helper accepted missing kernel.config checksum" >&2
	exit 1
fi
