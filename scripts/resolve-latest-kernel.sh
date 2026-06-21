#!/usr/bin/env bash
set -euo pipefail

releases_url="${YEET_KERNEL_RELEASES_JSON_URL:-https://www.kernel.org/releases.json}"

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

for cmd in awk basename curl dirname jq; do
	require "$cmd"
done

releases_json="$(curl -fsSL --retry 3 "$releases_url")"
latest_stable="$(jq -r '.latest_stable.version // empty' <<<"$releases_json")"
if [ -z "$latest_stable" ]; then
	echo "could not resolve latest stable kernel version from $releases_url" >&2
	exit 1
fi

release_json="$(
	jq -c --arg version "$latest_stable" '
	  [
	    .releases[]
	    | select(
	        .moniker == "stable" and
	        .version == $version and
	        .iseol == false
	      )
	  ]
	  | if length == 1 then .[0] else empty end
	' <<<"$releases_json"
)"
if [ -z "$release_json" ]; then
	echo "could not find non-EOL stable release for kernel $latest_stable" >&2
	exit 1
fi

moniker="$(jq -r '.moniker // empty' <<<"$release_json")"
version="$(jq -r '.version // empty' <<<"$release_json")"
source_url="$(jq -r '.source // empty' <<<"$release_json")"
released="$(jq -r '.released.isodate // empty' <<<"$release_json")"
if [ -z "$source_url" ]; then
	echo "kernel $latest_stable release is missing source URL" >&2
	exit 1
fi
if [ -z "$released" ]; then
	echo "kernel $latest_stable release is missing release isodate" >&2
	exit 1
fi

source_name="$(basename "$source_url")"
sha256sums_url="${YEET_KERNEL_SHA256SUMS_URL:-$(dirname "$source_url")/sha256sums.asc}"
source_sha256="$(
	curl -fsSL --retry 3 "$sha256sums_url" |
		awk -v source_name="$source_name" '($2 == source_name || $2 == "*" source_name) && !found { print $1; found = 1 }'
)"
if [ -z "$source_sha256" ]; then
	echo "could not find checksum for $source_name in $sha256sums_url" >&2
	exit 1
fi
if ! awk -v sha="$source_sha256" 'BEGIN { exit (length(sha) == 64 && sha !~ /[^0-9a-f]/ ? 0 : 1) }'; then
	echo "invalid sha256 for $source_name: $source_sha256" >&2
	exit 1
fi

jq -n \
	--arg moniker "$moniker" \
	--arg version "$version" \
	--arg source_url "$source_url" \
	--arg source_sha256 "$source_sha256" \
	--arg released "$released" \
	'{
	  moniker: $moniker,
	  version: $version,
	  source_url: $source_url,
	  source_sha256: $source_sha256,
	  released: $released
	}'
