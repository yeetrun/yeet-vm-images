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

if git -C "$repo_root" grep -n 'yeet[.]run'; then
	echo "repository contains invalid yeet[.]run references" >&2
	exit 1
fi

assert_contains "$sync_workflow" "kernel_release:"
assert_contains "$sync_workflow" "kernel_release_build:"
assert_contains "$sync_workflow" "promotion_needed:"
assert_contains "$sync_workflow" 'YEET_KERNEL_VERSION="$KERNEL_VERSION" \'
assert_contains "$sync_workflow" 'scripts/download-kernel-release.sh "$current_release" "$current_dir"'
assert_contains "$sync_workflow" 'manifest_sha256="$(sha256sum "$current_dir/kernel-manifest.json" | awk '"'"'{ print $1 }'"'"')"'
assert_contains "$sync_workflow" '.channels.amd64.stable == {kernel_id: $release, manifest_sha256: $manifest}'
assert_not_contains "$sync_workflow" "package_image_release"
assert_not_contains "$sync_workflow" "Kernel package source image release"

assert_job_contains "$sync_workflow" "build-kernel" "uses: ./.github/workflows/build-kernel.yml"
assert_job_contains "$sync_workflow" "build-kernel" 'kernel_release: ${{ needs.detect.outputs.kernel_release }}'
assert_not_contains "$sync_workflow" "  build-ubuntu:"
assert_not_contains "$sync_workflow" "  build-nixos:"
assert_not_contains "$sync_workflow" "uses: ./.github/workflows/build-ubuntu-26.04.yml"
assert_not_contains "$sync_workflow" "uses: ./.github/workflows/build-nixos-26.05.yml"
assert_job_contains "$sync_workflow" "publish-kernel-packages" "- detect"
assert_job_contains "$sync_workflow" "publish-kernel-packages" "- build-kernel"
assert_job_not_contains "$sync_workflow" "publish-kernel-packages" "- build-ubuntu"
assert_job_contains "$sync_workflow" "publish-kernel-packages" "needs.build-kernel.result == 'success' || needs.build-kernel.result == 'skipped'"
assert_job_contains "$sync_workflow" "publish-kernel-packages" 'kernel_release: ${{ needs.detect.outputs.kernel_release }}'
assert_contains "$sync_workflow" "scripts/update-kernel-catalog.sh"
assert_contains "$sync_workflow" "peter-evans/create-pull-request@"
assert_job_contains "$sync_workflow" "promote-kernel-catalog" "needs.publish-kernel-packages.result == 'success'"
assert_job_contains "$sync_workflow" "promote-kernel-catalog" "--channel stable"
assert_job_contains "$sync_workflow" "promote-kernel-catalog" "add-paths: kernel-catalog.json"

assert_contains "$publish_workflow" "kernel_release:"
assert_not_contains "$publish_workflow" "image_release:"
assert_contains "$publish_workflow" 'YEET_VM_KERNEL_RELEASE_ID="$KERNEL_RELEASE" \'
assert_contains "$publish_workflow" 'YEET_VM_KERNEL_MANIFEST_SHA256="$manifest_sha256" \'
assert_contains "$publish_workflow" 'releaseId = "$KERNEL_RELEASE";'
assert_contains "$publish_workflow" 'manifestSha256 = "$manifest_sha256";'
assert_contains "$publish_workflow" "Re-download and verify published selector metadata"
assert_contains "$publish_workflow" '"$page_url/kernel-packages/catalog.json"'
assert_contains "$publish_workflow" '"$page_url/apt/pool/main/$deb_name"'
