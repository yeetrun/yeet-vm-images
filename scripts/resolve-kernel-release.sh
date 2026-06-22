#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 <kernel-version> [tags-file]" >&2
	exit 2
}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	usage
fi

kernel_version="$1"
tags_file="${2:-}"

for cmd in awk jq; do
	require "$cmd"
done
if [ -z "$tags_file" ]; then
	require gh
fi

if [[ ! "$kernel_version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)*$ ]]; then
	echo "invalid kernel version: $kernel_version" >&2
	exit 1
fi
if [ -n "$tags_file" ] && [ ! -r "$tags_file" ]; then
	echo "tags file is not readable: $tags_file" >&2
	exit 1
fi

release_prefix="kernel-linux-${kernel_version}-yeet-v"

resolve_from_tags() {
	awk -v prefix="$release_prefix" '
	  BEGIN { max = 0 }
	  {
	    tag = $0
	    if (index(tag, prefix) == 1) {
	      revision = substr(tag, length(prefix) + 1)
	      if (revision ~ /^[1-9][0-9]*$/ && revision + 0 > max) {
	        max = revision + 0
	      }
	    }
	  }
	  END { print max }
	'
}

if [ -n "$tags_file" ]; then
	current_revision="$(resolve_from_tags <"$tags_file")"
else
	current_revision="$(
		gh release list --limit 200 --json tagName --jq '.[].tagName' |
			resolve_from_tags
	)"
fi

current_release=""
if [ "$current_revision" -gt 0 ]; then
	current_release="${release_prefix}${current_revision}"
fi
next_revision="$((current_revision + 1))"
next_release="${release_prefix}${next_revision}"

jq -n \
	--arg upstream_kernel_version "$kernel_version" \
	--arg kernel_version "linux-${kernel_version}-yeet" \
	--arg current_release "$current_release" \
	--arg next_release "$next_release" \
	--argjson current_revision "$current_revision" \
	--argjson next_revision "$next_revision" \
	'{
	  upstream_kernel_version: $upstream_kernel_version,
	  kernel_version: $kernel_version,
	  current_revision: $current_revision,
	  current_release: $current_release,
	  next_revision: $next_revision,
	  next_release: $next_release
	}'
