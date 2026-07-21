#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 --guest-base-id <id> --os <ubuntu|nixos> --os-version <version> --architecture amd64 --rootfs <path> --uncompressed-bytes <bytes> --default-kernel-channel <stable|candidate> --source-commit <sha> --workflow-run-url <url> --out <path>" >&2
	exit 2
}

guest_base_id=""
guest_os=""
os_version=""
architecture=""
rootfs=""
uncompressed_bytes=""
default_kernel_channel=""
source_commit=""
workflow_run_url=""
out=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--guest-base-id) guest_base_id="$2"; shift 2 ;;
		--os) guest_os="$2"; shift 2 ;;
		--os-version) os_version="$2"; shift 2 ;;
		--architecture) architecture="$2"; shift 2 ;;
		--rootfs) rootfs="$2"; shift 2 ;;
		--uncompressed-bytes) uncompressed_bytes="$2"; shift 2 ;;
		--default-kernel-channel) default_kernel_channel="$2"; shift 2 ;;
		--source-commit) source_commit="$2"; shift 2 ;;
		--workflow-run-url) workflow_run_url="$2"; shift 2 ;;
		--out) out="$2"; shift 2 ;;
		*) usage ;;
	esac
done

for value in guest_base_id guest_os os_version architecture rootfs uncompressed_bytes default_kernel_channel source_commit workflow_run_url out; do
	[ -n "${!value:-}" ] || usage
done
for cmd in awk jq mkdir sha256sum; do
	command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

[ "$guest_os" = ubuntu ] || [ "$guest_os" = nixos ] || { echo "unsupported guest OS: $guest_os" >&2; exit 1; }
[[ "$os_version" =~ ^[0-9]+[.][0-9]+$ ]] || { echo "invalid guest OS version: $os_version" >&2; exit 1; }
[ "$architecture" = amd64 ] || { echo "unsupported guest architecture: $architecture" >&2; exit 1; }
[[ "$uncompressed_bytes" =~ ^[1-9][0-9]*$ ]] || { echo "invalid uncompressed rootfs size: $uncompressed_bytes" >&2; exit 1; }
[ "$default_kernel_channel" = stable ] || [ "$default_kernel_channel" = candidate ] || { echo "invalid default kernel channel: $default_kernel_channel" >&2; exit 1; }
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid source commit: $source_commit" >&2; exit 1; }
[[ "$workflow_run_url" =~ ^https://github[.]com/yeetrun/yeet-vm-images/actions/runs/[1-9][0-9]*$ ]] || { echo "invalid workflow run URL: $workflow_run_url" >&2; exit 1; }
guest_base_prefix="guest-${guest_os}-${os_version}-${architecture}-v"
guest_revision="${guest_base_id#"$guest_base_prefix"}"
if [ "$guest_revision" = "$guest_base_id" ] || ! [[ "$guest_revision" =~ ^[1-9][0-9]*$ ]]; then
	echo "guest base ID does not match OS identity: $guest_base_id" >&2
	exit 1
fi
[ -s "$rootfs" ] || { echo "compressed rootfs is missing or empty: $rootfs" >&2; exit 1; }

rootfs_sha256="$(sha256sum "$rootfs" | awk '{ print $1 }')"
asset_url="https://github.com/yeetrun/yeet-vm-images/releases/download/${guest_base_id}/rootfs.ext4.zst"
mkdir -p "$(dirname "$out")"
jq -n \
	--arg guest_base_id "$guest_base_id" \
	--arg os "$guest_os" \
	--arg os_version "$os_version" \
	--arg architecture "$architecture" \
	--arg asset_url "$asset_url" \
	--arg rootfs_sha256 "$rootfs_sha256" \
	--argjson uncompressed_bytes "$uncompressed_bytes" \
	--arg default_kernel_channel "$default_kernel_channel" \
	--arg source_commit "$source_commit" \
	--arg workflow_run_url "$workflow_run_url" '
	{
		schema_version: 1,
		guest_base_id: $guest_base_id,
		os: $os,
		os_version: $os_version,
		architecture: $architecture,
		rootfs: {
			url: $asset_url,
			sha256: $rootfs_sha256,
			uncompressed_bytes: $uncompressed_bytes
		},
		default_kernel_channel: $default_kernel_channel,
		provenance: {
			source_commit: $source_commit,
			workflow_run_url: $workflow_run_url
		}
	}' >"$out"
