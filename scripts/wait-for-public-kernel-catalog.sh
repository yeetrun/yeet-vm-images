#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 <catalog-url> <kernel-release-id> <manifest-sha256>" >&2
	exit 2
}

if [ "$#" -ne 3 ]; then
	usage
fi

catalog_url="$1"
release_id="$2"
manifest_sha256="$3"
settle_seconds="${YEET_KERNEL_CATALOG_SETTLE_SECONDS:-305}"
attempts="${YEET_KERNEL_CATALOG_ATTEMPTS:-12}"
retry_seconds="${YEET_KERNEL_CATALOG_RETRY_SECONDS:-10}"

if [ -z "$catalog_url" ]; then
	echo "catalog URL must not be empty" >&2
	exit 1
fi
if [[ ! "$release_id" =~ ^kernel-linux-[0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$ ]]; then
	echo "invalid kernel release ID: $release_id" >&2
	exit 1
fi
if [[ ! "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]]; then
	echo "invalid kernel manifest SHA-256: $manifest_sha256" >&2
	exit 1
fi
for value_name in settle_seconds attempts retry_seconds; do
	value="${!value_name}"
	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		echo "$value_name must be a non-negative integer, got: $value" >&2
		exit 1
	fi
done
if [ "$attempts" -lt 1 ]; then
	echo "attempts must be at least 1" >&2
	exit 1
fi

tmp_catalog="$(mktemp)"
trap 'rm -f "$tmp_catalog"' EXIT

if [ "$settle_seconds" -gt 0 ]; then
	echo "waiting ${settle_seconds}s before checking the public kernel catalog"
	sleep "$settle_seconds"
fi

catalog_matches() {
	curl -fsSL --retry 3 --retry-all-errors -o "$tmp_catalog" "$catalog_url" &&
		jq -e \
			--arg release "$release_id" \
			--arg manifest "$manifest_sha256" '
			.schema_version == 1 and
			any(.kernels[]; .kernel_id == $release and .manifest_sha256 == $manifest) and
			.channels.amd64.stable == {kernel_id: $release, manifest_sha256: $manifest}
		' "$tmp_catalog" >/dev/null
}

wait_for_match() {
	local phase="$1"
	local attempt=1
	while [ "$attempt" -le "$attempts" ]; do
		if catalog_matches; then
			return 0
		fi
		if [ "$attempt" -lt "$attempts" ] && [ "$retry_seconds" -gt 0 ]; then
			sleep "$retry_seconds"
		fi
		attempt="$((attempt + 1))"
	done
	echo "public kernel catalog did not $phase $release_id at $manifest_sha256 after $attempts attempt(s)" >&2
	return 1
}

wait_for_match "select"
if [ "$settle_seconds" -gt 0 ]; then
	echo "public kernel catalog selects $release_id; waiting another ${settle_seconds}s to drain older cache entries"
	sleep "$settle_seconds"
fi
wait_for_match "remain on"
echo "public kernel catalog stably selects $release_id at $manifest_sha256"
