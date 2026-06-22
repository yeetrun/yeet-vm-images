#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
	local file="$1"
	local needle="$2"
	if ! grep -Fq "$needle" "$file"; then
		echo "$file does not contain: $needle" >&2
		exit 1
	fi
}

assert_not_contains() {
	local file="$1"
	local needle="$2"
	if grep -Fq "$needle" "$file"; then
		echo "$file still contains: $needle" >&2
		exit 1
	fi
}

assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "kernel_release:"
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "kernel_release_build:"
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "build-kernel:"
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "uses: ./.github/workflows/build-kernel.yml"
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" 'kernel_release: ${{ needs.detect.outputs.kernel_release }}'
assert_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped'"
assert_not_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "package_image_release"
assert_not_contains "$repo_root/.github/workflows/sync-latest-stable-kernel.yml" "Kernel package source image release"

assert_contains "$repo_root/.github/workflows/publish-kernel-packages.yml" "kernel_release:"
assert_not_contains "$repo_root/.github/workflows/publish-kernel-packages.yml" "image_release:"
