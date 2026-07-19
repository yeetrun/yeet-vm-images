#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_firecracker_version="v1.16.1"

assert_contains() {
	local file="$1"
	local expected="$2"

	if ! grep -Fq -- "$expected" "$repo_root/$file"; then
		echo "$file is missing expected jailer bundle contract: $expected" >&2
		exit 1
	fi
}

for builder in \
	scripts/build-ubuntu-26.04.sh \
	scripts/build-nixos-26.05.sh
do
	assert_contains "$builder" "firecracker_version=\"\${FIRECRACKER_VERSION:-$expected_firecracker_version}\""
	assert_contains "$builder" 'install -m 0755 "$fc_dir/jailer-${firecracker_version}-${firecracker_arch}" "$out_dir/jailer"'
	assert_contains "$builder" 'jailer_sha="$(sha256sum "$out_dir/jailer" | awk '\''{ print $1 }'\'')"'
	assert_contains "$builder" '  "jailer": "jailer",'
	assert_contains "$builder" '    "jailer": "$jailer_sha"'
	assert_contains "$builder" 'rootfs.ext4.zst firecracker jailer'
done

for workflow in \
	.github/workflows/build-ubuntu-26.04.yml \
	.github/workflows/build-nixos-26.05.yml
do
	default_count="$(grep -Fc -- "default: $expected_firecracker_version" "$repo_root/$workflow")"
	if [ "$default_count" -ne 2 ]; then
		echo "$workflow has $default_count Firecracker $expected_firecracker_version defaults, want 2" >&2
		exit 1
	fi
	assert_contains "$workflow" 'for asset in manifest.json vmlinux rootfs.ext4.zst firecracker jailer kernel.config checksums.txt; do'
	assert_contains "$workflow" 'check_manifest_checksum jailer'
	assert_contains "$workflow" 'firecracker_version_actual="$("$OUT_DIR/firecracker" --version)"'
	assert_contains "$workflow" 'if [ "$firecracker_version_actual" != "Firecracker $FIRECRACKER_VERSION" ]; then'
	assert_contains "$workflow" '.jailer == "jailer" and'
	assert_contains "$workflow" '.provenance.firecracker_version == env.FIRECRACKER_VERSION and'
	assert_contains "$workflow" '"$OUT_DIR/jailer" --version'
	assert_contains "$workflow" 'if [ "$jailer_version" != "Jailer $FIRECRACKER_VERSION" ]; then'
done

sync_workflow=.github/workflows/sync-latest-stable-kernel.yml
sync_count="$(grep -Fc -- "firecracker_version: $expected_firecracker_version" "$repo_root/$sync_workflow")"
if [ "$sync_count" -ne 2 ]; then
	echo "$sync_workflow has $sync_count Firecracker $expected_firecracker_version inputs, want 2" >&2
	exit 1
fi

echo "Firecracker jailer image bundle contract verified"
