#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
	echo "usage: $0 <guest-base-id> <title> <target> <notes-file> <out-dir>" >&2
	exit 2
fi

guest_base_id="$1"
title="$2"
target="$3"
notes_file="$4"
out_dir="$5"
upload_timeout="${YEET_RELEASE_UPLOAD_TIMEOUT:-30m}"
assets=(rootfs.ext4.zst guest-manifest.json checksums.txt provenance.json)
release_created=0
release_published=0

cleanup_draft() {
	if [ "$release_created" -eq 1 ] && [ "$release_published" -eq 0 ]; then
		echo "Deleting incomplete draft release $guest_base_id" >&2
		gh release delete "$guest_base_id" --cleanup-tag --yes >/dev/null 2>&1 || true
	fi
}

on_error() {
	local result="$?"
	cleanup_draft
	exit "$result"
}
trap on_error ERR INT TERM

if ! [[ "$guest_base_id" =~ ^guest-(ubuntu|nixos)-[0-9]+[.][0-9]+-amd64-v[1-9][0-9]*$ ]]; then
	echo "invalid guest base ID: $guest_base_id" >&2
	exit 1
fi
for asset in "${assets[@]}"; do
	[ -s "$out_dir/$asset" ] || { echo "guest-base release asset is missing or empty: $asset" >&2; exit 1; }
done
actual="$(find "$out_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
expected="$(printf '%s\n' "${assets[@]}" | LC_ALL=C sort)"
[ "$actual" = "$expected" ] || { echo "guest-base release staging contains an unexpected asset" >&2; exit 1; }

gh release create "$guest_base_id" \
	--draft \
	--target "$target" \
	--title "$title" \
	--notes-file "$notes_file"
release_created=1

for asset in "${assets[@]}"; do
	echo "Uploading $asset to $guest_base_id"
	if command -v timeout >/dev/null 2>&1; then
		timeout "$upload_timeout" gh release upload "$guest_base_id" "$out_dir/$asset"
	else
		gh release upload "$guest_base_id" "$out_dir/$asset"
	fi
done

gh release edit "$guest_base_id" --draft=false
release_published=1
trap - ERR INT TERM
