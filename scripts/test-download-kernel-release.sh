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
	local manifest_filter="${3:-.}"
	jq -n \
		--arg vmlinux_sha "$vmlinux_checksum" \
		--arg kernel_config_sha "$kernel_config_checksum" \
		'{
		  schema_version: 1,
		  kernel_id: "kernel-linux-7.1.1-yeet-v2",
		  upstream_version: "7.1.1",
		  packaging_revision: 2,
		  architecture: "amd64",
		  vmlinux: {
		    url: "https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.1-yeet-v2/vmlinux",
		    sha256: $vmlinux_sha
		  },
		  config: {
		    url: "https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.1-yeet-v2/kernel.config",
		    sha256: $kernel_config_sha
		  },
		  guest_packages: {
		    catalog_url: "https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-packages/catalog.json",
		    selector_schema_version: 2,
		    release_id: "kernel-linux-7.1.1-yeet-v2"
		  },
		  provenance: {
		    source_commit: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		    workflow_run_url: "https://github.com/yeetrun/yeet-vm-images/actions/runs/123456790"
		  }
		}' | jq "$manifest_filter" >"$remote_dir/kernel-manifest.json"
}

run_download() {
	local output_dir="$1"
	shift
	PATH="$fake_bin:$PATH" \
		GITHUB_REPOSITORY=yeetrun/yeet-vm-images \
		YEET_TEST_REMOTE_DIR="$remote_dir" \
		YEET_KERNEL_VERSION=7.1.1 \
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

write_manifest "$vmlinux_sha" "$kernel_config_sha" 'del(.config.sha256)'
if run_download "$tmp_dir/missing-kernel-config-checksum" >/dev/null 2>&1; then
	echo "download helper accepted missing kernel.config checksum" >&2
	exit 1
fi

write_manifest "$vmlinux_sha" "$kernel_config_sha" '.provenance.source_commit = "short"'
if run_download "$tmp_dir/bad-provenance" >/dev/null 2>&1; then
	echo "download helper accepted malformed provenance" >&2
	exit 1
fi
