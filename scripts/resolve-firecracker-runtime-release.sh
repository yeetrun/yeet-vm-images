#!/usr/bin/env bash
set -euo pipefail

LC_ALL=C
export LC_ALL

usage() {
	echo "usage: $0 <upstream-version> [tags-file]" >&2
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

upstream_version="$1"
tags_mode=false
tags_file=""
if [ "$#" -eq 2 ]; then
	tags_mode=true
	tags_file="$2"
fi

require jq
if [[ ! "$upstream_version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
	echo "invalid upstream version: $upstream_version" >&2
	exit 1
fi

tmp_dir=""
cleanup() {
	if [ -n "$tmp_dir" ]; then
		rm -rf "$tmp_dir"
	fi
}
trap cleanup EXIT

if [ "$tags_mode" = true ]; then
	if [ ! -r "$tags_file" ]; then
		echo "tags file is not readable: $tags_file" >&2
		exit 1
	fi
else
	require git
	tmp_dir="$(mktemp -d)"
	tags_file="$tmp_dir/tags.txt"
	if ! remote_tags="$(git ls-remote --tags --refs origin)"; then
		echo "could not list immutable release tags from origin" >&2
		exit 1
	fi
	awk -F '\t' '
	  NF == 2 && $2 ~ /^refs\/tags\// {
	    sub(/^refs\/tags\//, "", $2)
	    print $2
	  }
	' <<<"$remote_tags" >"$tags_file"
fi

release_prefix="firecracker-${upstream_version}-yeet-v"
seen_revisions="${tmp_dir:-$(mktemp -d)}/seen-revisions.txt"
if [ -z "$tmp_dir" ]; then
	tmp_dir="${seen_revisions%/*}"
fi
: >"$seen_revisions"

max_current_revision=9007199254740990
current_revision=0

decimal_greater_than() {
	left="$1"
	right="$2"
	if [ "${#left}" -gt "${#right}" ]; then
		return 0
	fi
	if [ "${#left}" -lt "${#right}" ]; then
		return 1
	fi
	[[ "$left" > "$right" ]]
}

while IFS= read -r tag || [ -n "$tag" ]; do
	case "$tag" in
		"$release_prefix"*)
			revision="${tag#"$release_prefix"}"
			if [[ ! "$revision" =~ ^[1-9][0-9]*$ ]]; then
				continue
			fi
			if grep -Fxq -- "$revision" "$seen_revisions"; then
				echo "duplicate or ambiguous packaging revision $revision for $upstream_version" >&2
				exit 1
			fi
			printf '%s\n' "$revision" >>"$seen_revisions"
			if decimal_greater_than "$revision" "$max_current_revision"; then
				echo "packaging revision overflow for $tag" >&2
				exit 1
			fi
			if decimal_greater_than "$revision" "$current_revision"; then
				current_revision="$revision"
			fi
			;;
	esac
done <"$tags_file"

current_release=""
if [ "$current_revision" -gt 0 ]; then
	current_release="${release_prefix}${current_revision}"
fi
next_revision="$((current_revision + 1))"
next_release="${release_prefix}${next_revision}"

if grep -Fxq -- "$next_release" "$tags_file"; then
	echo "ambiguous packaging tags: computed next release already exists: $next_release" >&2
	exit 1
fi

jq -n \
	--arg upstream_version "$upstream_version" \
	--arg current_release "$current_release" \
	--arg next_release "$next_release" \
	--argjson current_revision "$current_revision" \
	--argjson next_revision "$next_revision" \
	'{
	  upstream_version: $upstream_version,
	  current_revision: $current_revision,
	  current_release: $current_release,
	  next_revision: $next_revision,
	  next_release: $next_release
	}'
