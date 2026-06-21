#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
	echo "usage: $0 <tag> <title> <target> <notes-file> <out-dir>" >&2
	exit 2
fi

tag="$1"
title="$2"
target="$3"
notes_file="$4"
out_dir="$5"
upload_timeout="${YEET_RELEASE_UPLOAD_TIMEOUT:-30m}"
assets=(
	rootfs.ext4.zst
	manifest.json
	vmlinux
	firecracker
	kernel.config
	checksums.txt
)
release_created=0
release_published=0

file_size() {
	local path="$1"
	if stat -c %s "$path" >/dev/null 2>&1; then
		stat -c %s "$path"
	else
		stat -f %z "$path"
	fi
}

cleanup_draft() {
	if [ "$release_created" -eq 1 ] && [ "$release_published" -eq 0 ]; then
		echo "Deleting incomplete draft release $tag" >&2
		gh release delete "$tag" --yes >/dev/null 2>&1 || true
	fi
}

on_error() {
	local status="$?"
	cleanup_draft
	exit "$status"
}
trap on_error ERR INT TERM

for asset in "${assets[@]}"; do
	path="$out_dir/$asset"
	if [ ! -s "$path" ]; then
		echo "release asset is missing or empty: $path" >&2
		exit 1
	fi
done

gh release create "$tag" \
	--draft \
	--target "$target" \
	--title "$title" \
	--notes-file "$notes_file"
release_created=1

for asset in "${assets[@]}"; do
	path="$out_dir/$asset"
	size="$(file_size "$path")"
	echo "Uploading $asset ($size bytes) to $tag"
	if command -v timeout >/dev/null 2>&1; then
		timeout "$upload_timeout" gh release upload "$tag" "$path" --clobber
	else
		gh release upload "$tag" "$path" --clobber
	fi
	echo "Uploaded $asset"
done

gh release edit "$tag" --draft=false
release_published=1
trap - ERR INT TERM
