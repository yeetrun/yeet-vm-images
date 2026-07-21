#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
	echo "usage: $0 --manifest <path> --manifest-sha256 <sha256> --channel <stable|candidate> --catalog-in <path> --catalog-out <path>" >&2
	exit 2
}

manifest=""
manifest_sha256=""
channel=""
catalog_in=""
catalog_out=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--manifest) manifest="${2:-}"; shift 2 ;;
		--manifest-sha256) manifest_sha256="${2:-}"; shift 2 ;;
		--channel) channel="${2:-}"; shift 2 ;;
		--catalog-in) catalog_in="${2:-}"; shift 2 ;;
		--catalog-out) catalog_out="${2:-}"; shift 2 ;;
		*) usage ;;
	esac
done

for value in manifest manifest_sha256 channel catalog_in catalog_out; do
	[ -n "${!value}" ] || usage
done
for cmd in awk jq mkdir sha256sum; do
	command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done
[ -r "$manifest" ] || { echo "kernel manifest is not readable: $manifest" >&2; exit 1; }
[ -r "$catalog_in" ] || { echo "kernel catalog is not readable: $catalog_in" >&2; exit 1; }
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid manifest SHA-256" >&2; exit 1; }
[ "$channel" = "stable" ] || [ "$channel" = "candidate" ] || { echo "invalid kernel channel: $channel" >&2; exit 1; }
actual_manifest_sha="$(sha256sum "$manifest" | awk '{ print $1 }')"
[ "$actual_manifest_sha" = "$manifest_sha256" ] || { echo "kernel manifest SHA-256 mismatch" >&2; exit 1; }

jq -e '
	.schema_version == 1 and
	.kernel_id == "kernel-linux-\(.upstream_version)-yeet-v\(.packaging_revision)" and
	.architecture == "amd64" and
	.guest_packages.selector_schema_version == 2 and
	.guest_packages.release_id == .kernel_id and
	(.vmlinux.sha256 | test("^[0-9a-f]{64}$")) and
	(.config.sha256 | test("^[0-9a-f]{64}$"))
' "$manifest" >/dev/null || { echo "invalid kernel manifest" >&2; exit 1; }

kernel_id="$(jq -r '.kernel_id' "$manifest")"
upstream_version="$(jq -r '.upstream_version' "$manifest")"
packaging_revision="$(jq -r '.packaging_revision' "$manifest")"
architecture="$(jq -r '.architecture' "$manifest")"
manifest_url="https://github.com/yeetrun/yeet-vm-images/releases/download/${kernel_id}/kernel-manifest.json"
entry="$(jq -n \
	--arg kernel_id "$kernel_id" \
	--arg upstream_version "$upstream_version" \
	--argjson packaging_revision "$packaging_revision" \
	--arg architecture "$architecture" \
	--arg manifest_url "$manifest_url" \
	--arg manifest_sha256 "$manifest_sha256" '
	{
		kernel_id: $kernel_id,
		upstream_version: $upstream_version,
		packaging_revision: $packaging_revision,
		architecture: $architecture,
		manifest_url: $manifest_url,
		manifest_sha256: $manifest_sha256
	}')"

mkdir -p "$(dirname "$catalog_out")"
jq \
	--arg channel "$channel" \
	--arg kernel_id "$kernel_id" \
	--arg manifest_sha256 "$manifest_sha256" \
	--argjson entry "$entry" '
	.kernels = (([.kernels[] | select(.kernel_id != $kernel_id)] + [$entry]) | sort_by(.kernel_id)) |
	.channels.amd64[$channel] = {kernel_id: $kernel_id, manifest_sha256: $manifest_sha256}
' "$catalog_in" >"$catalog_out"
