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
		--manifest) manifest="$2"; shift 2 ;;
		--manifest-sha256) manifest_sha256="$2"; shift 2 ;;
		--channel) channel="$2"; shift 2 ;;
		--catalog-in) catalog_in="$2"; shift 2 ;;
		--catalog-out) catalog_out="$2"; shift 2 ;;
		*) usage ;;
	esac
done

for value in manifest manifest_sha256 channel catalog_in catalog_out; do
	[ -n "${!value:-}" ] || usage
done
for cmd in awk jq mkdir sha256sum; do
	command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done
[ -r "$manifest" ] || { echo "guest manifest is not readable: $manifest" >&2; exit 1; }
[ -r "$catalog_in" ] || { echo "guest catalog is not readable: $catalog_in" >&2; exit 1; }
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid manifest SHA-256" >&2; exit 1; }
[ "$channel" = stable ] || [ "$channel" = candidate ] || { echo "invalid guest channel: $channel" >&2; exit 1; }
[ "$(sha256sum "$manifest" | awk '{ print $1 }')" = "$manifest_sha256" ] || { echo "guest manifest SHA-256 mismatch" >&2; exit 1; }

jq -e '
	.schema_version == 1 and
	(.os == "ubuntu" or .os == "nixos") and
	.architecture == "amd64" and
	.guest_base_id == "guest-\(.os)-\(.os_version)-\(.architecture)-" + (.guest_base_id | capture("-(?<revision>v[1-9][0-9]*)$").revision) and
	.rootfs.url == "https://github.com/yeetrun/yeet-vm-images/releases/download/\(.guest_base_id)/rootfs.ext4.zst" and
	(.rootfs.sha256 | test("^[0-9a-f]{64}$")) and
	(.rootfs.uncompressed_bytes | type == "number" and floor == . and . > 0) and
	(.default_kernel_channel == "stable" or .default_kernel_channel == "candidate")
' "$manifest" >/dev/null || { echo "invalid guest manifest" >&2; exit 1; }

guest_base_id="$(jq -r '.guest_base_id' "$manifest")"
guest_os="$(jq -r '.os' "$manifest")"
os_version="$(jq -r '.os_version' "$manifest")"
architecture="$(jq -r '.architecture' "$manifest")"
catalog_channel="${guest_os}-${os_version}-${architecture}"
manifest_url="https://github.com/yeetrun/yeet-vm-images/releases/download/${guest_base_id}/guest-manifest.json"
entry="$(jq -n \
	--arg guest_base_id "$guest_base_id" \
	--arg os "$guest_os" \
	--arg os_version "$os_version" \
	--arg architecture "$architecture" \
	--arg manifest_url "$manifest_url" \
	--arg manifest_sha256 "$manifest_sha256" '
	{
		guest_base_id: $guest_base_id,
		os: $os,
		os_version: $os_version,
		architecture: $architecture,
		manifest_url: $manifest_url,
		manifest_sha256: $manifest_sha256
	}')"

mkdir -p "$(dirname "$catalog_out")"
jq \
	--arg channel "$channel" \
	--arg catalog_channel "$catalog_channel" \
	--arg guest_base_id "$guest_base_id" \
	--arg manifest_sha256 "$manifest_sha256" \
	--argjson entry "$entry" '
	.guest_bases = (([.guest_bases[] | select(.guest_base_id != $guest_base_id)] + [$entry]) | sort_by(.guest_base_id)) |
	.channels[$catalog_channel][$channel] = {guest_base_id: $guest_base_id, manifest_sha256: $manifest_sha256}
' "$catalog_in" >"$catalog_out"
