#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 <family-prefix> <kernel-version> [tags-file]" >&2
	exit 2
}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	usage
fi

family="$1"
kernel_version="$2"
tags_file="${3:-}"

for cmd in awk jq; do
	require "$cmd"
done
if [ -z "$tags_file" ]; then
	require gh
fi

if [[ ! "$family" =~ ^[a-z0-9][a-z0-9-]*-[0-9]+[.][0-9]+-amd64$ ]]; then
	echo "invalid family prefix: $family" >&2
	exit 1
fi
if [[ ! "$kernel_version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)*$ ]]; then
	echo "invalid kernel version: $kernel_version" >&2
	exit 1
fi
if [ -n "$tags_file" ] && [ ! -r "$tags_file" ]; then
	echo "tags file is not readable: $tags_file" >&2
	exit 1
fi

next_revision_from_tags() {
	awk -v family="$family" '
	  BEGIN {
	    max = 0
	    legacy_prefix = family "-v"
	    hybrid_prefix = family "-kernel-"
	  }
	  {
	    tag = $0
	    if (index(tag, legacy_prefix) == 1) {
	      revision = substr(tag, length(legacy_prefix) + 1)
	      if (revision ~ /^[0-9]+$/ && revision + 0 > max) {
	        max = revision + 0
	      }
	    }
	    if (index(tag, hybrid_prefix) == 1) {
	      rest = substr(tag, length(hybrid_prefix) + 1)
	      if (rest ~ /^[0-9]+([.][0-9]+)*-v[0-9]+$/) {
	        sub(/^.*-v/, "", rest)
	        if (rest + 0 > max) {
	          max = rest + 0
	        }
	      }
	    }
	  }
	  END { print max + 1 }
	'
}

if [ -n "$tags_file" ]; then
	image_revision="$(next_revision_from_tags <"$tags_file")"
else
	image_revision="$(
		gh release list --limit 200 --json tagName --jq '.[].tagName' |
			next_revision_from_tags
	)"
fi

version="${family}-kernel-${kernel_version}-v${image_revision}"
jq -n \
	--arg family "$family" \
	--arg upstream_kernel_version "$kernel_version" \
	--argjson image_revision "$image_revision" \
	--arg version "$version" \
	'{
	  family: $family,
	  upstream_kernel_version: $upstream_kernel_version,
	  image_revision: $image_revision,
	  version: $version
	}'
