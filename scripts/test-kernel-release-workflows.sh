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

job_block() {
	local file="$1"
	local job="$2"
	awk -v job="$job" '
		$0 == "  " job ":" { in_job = 1; print; next }
		in_job && $0 ~ /^  [A-Za-z0-9_-]+:/ { exit }
		in_job { print }
	' "$file"
}

assert_job_contains() {
	local file="$1"
	local job="$2"
	local needle="$3"
	if ! job_block "$file" "$job" | grep -Fq -- "$needle"; then
		echo "$file job $job does not contain: $needle" >&2
		exit 1
	fi
}

assert_job_not_contains() {
	local file="$1"
	local job="$2"
	local needle="$3"
	if job_block "$file" "$job" | grep -Fq -- "$needle"; then
		echo "$file job $job still contains: $needle" >&2
		exit 1
	fi
}

sync_workflow="$repo_root/.github/workflows/sync-latest-stable-kernel.yml"
publish_workflow="$repo_root/.github/workflows/publish-kernel-packages.yml"

assert_contains "$sync_workflow" "kernel_release:"
assert_contains "$sync_workflow" "kernel_release_build:"
assert_contains "$sync_workflow" 'YEET_KERNEL_VERSION="$KERNEL_VERSION" \'
assert_contains "$sync_workflow" 'YEET_KERNEL_SOURCE_URL="${{ steps.kernel.outputs.kernel_source_url }}" \'
assert_contains "$sync_workflow" 'YEET_KERNEL_SOURCE_SHA256="${{ steps.kernel.outputs.kernel_source_sha256 }}" \'
assert_contains "$sync_workflow" 'YEET_KERNEL_CONFIG_URL="https://raw.githubusercontent.com/firecracker-microvm/firecracker/86a2559b26a4b9a05405aeaa58bab0f7261d71bc/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config" \'
assert_contains "$sync_workflow" 'scripts/download-kernel-release.sh "$kernel_current_release" "$RUNNER_TEMP/current-kernel-release"'
assert_not_contains "$sync_workflow" "package_image_release"
assert_not_contains "$sync_workflow" "Kernel package source image release"

assert_job_contains "$sync_workflow" "build-kernel" "uses: ./.github/workflows/build-kernel.yml"
assert_job_contains "$sync_workflow" "build-kernel" 'kernel_release: ${{ needs.detect.outputs.kernel_release }}'
assert_job_contains "$sync_workflow" "build-ubuntu" "- build-kernel"
assert_job_contains "$sync_workflow" "build-ubuntu" "needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped'"
assert_job_contains "$sync_workflow" "build-ubuntu" 'kernel_release: ${{ needs.detect.outputs.kernel_release }}'
assert_job_contains "$sync_workflow" "build-nixos" "- build-kernel"
assert_job_contains "$sync_workflow" "build-nixos" "- publish-kernel-packages"
assert_job_contains "$sync_workflow" "build-nixos" "needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped'"
assert_job_contains "$sync_workflow" "build-nixos" 'yeet_vm_images_ref: ${{ needs.publish-kernel-packages.outputs.metadata_commit }}'
assert_job_contains "$sync_workflow" "build-nixos" 'kernel_release: ${{ needs.detect.outputs.kernel_release }}'
assert_job_contains "$sync_workflow" "publish-kernel-packages" "- detect"
assert_job_contains "$sync_workflow" "publish-kernel-packages" "- build-kernel"
assert_job_not_contains "$sync_workflow" "publish-kernel-packages" "- build-ubuntu"
assert_job_contains "$sync_workflow" "publish-kernel-packages" "needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped'"
assert_job_contains "$sync_workflow" "publish-kernel-packages" 'kernel_release: ${{ needs.detect.outputs.kernel_release }}'

assert_contains "$publish_workflow" "kernel_release:"
assert_not_contains "$publish_workflow" "image_release:"
