#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

renderer="$repo_root/scripts/render-guest-manifest.sh"
updater="$repo_root/scripts/update-guest-catalog.sh"
builder="$repo_root/scripts/build-ubuntu-26.04.sh"
workflow="$repo_root/.github/workflows/build-ubuntu-26.04.yml"

test -x "$renderer"
test -x "$updater"

printf 'compressed rootfs\n' >"$tmp_dir/rootfs.ext4.zst"
rootfs_sha="$(sha256sum "$tmp_dir/rootfs.ext4.zst" | awk '{ print $1 }')"
guest_base_id=guest-ubuntu-26.04-amd64-v1
source_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
workflow_run_url=https://github.com/yeetrun/yeet-vm-images/actions/runs/123456791

"$renderer" \
	--guest-base-id "$guest_base_id" \
	--os ubuntu \
	--os-version 26.04 \
	--architecture amd64 \
	--rootfs "$tmp_dir/rootfs.ext4.zst" \
	--uncompressed-bytes 4294967296 \
	--default-kernel-channel stable \
	--source-commit "$source_commit" \
	--workflow-run-url "$workflow_run_url" \
	--out "$tmp_dir/guest-manifest.json"

if "$renderer" \
	--guest-base-id guest-ubuntu-26x04-amd64-v1 \
	--os ubuntu \
	--os-version 26.04 \
	--architecture amd64 \
	--rootfs "$tmp_dir/rootfs.ext4.zst" \
	--uncompressed-bytes 4294967296 \
	--default-kernel-channel stable \
	--source-commit "$source_commit" \
	--workflow-run-url "$workflow_run_url" \
	--out "$tmp_dir/invalid-guest-manifest.json" >/dev/null 2>&1
then
	echo "guest manifest renderer accepted a non-canonical ID" >&2
	exit 1
fi

jq -e \
	--arg rootfs_sha "$rootfs_sha" \
	--arg source_commit "$source_commit" \
	--arg workflow_run_url "$workflow_run_url" '
	keys == ["architecture", "default_kernel_channel", "guest_base_id", "os", "os_version", "provenance", "rootfs", "schema_version"] and
	.schema_version == 1 and
	.guest_base_id == "guest-ubuntu-26.04-amd64-v1" and
	.os == "ubuntu" and
	.os_version == "26.04" and
	.architecture == "amd64" and
	.rootfs == {
		url: "https://github.com/yeetrun/yeet-vm-images/releases/download/guest-ubuntu-26.04-amd64-v1/rootfs.ext4.zst",
		sha256: $rootfs_sha,
		uncompressed_bytes: 4294967296
	} and
	.default_kernel_channel == "stable" and
	.provenance == {source_commit: $source_commit, workflow_run_url: $workflow_run_url} and
	([paths(scalars) as $path | getpath($path) | strings] | all(. != "firecracker" and . != "jailer" and . != "vmlinux" and . != "kernel.config"))
' "$tmp_dir/guest-manifest.json" >/dev/null

manifest_sha="$(sha256sum "$tmp_dir/guest-manifest.json" | awk '{ print $1 }')"
"$updater" \
	--manifest "$tmp_dir/guest-manifest.json" \
	--manifest-sha256 "$manifest_sha" \
	--channel candidate \
	--catalog-in "$repo_root/guest-catalog.json" \
	--catalog-out "$tmp_dir/guest-catalog.json"

jq -e --arg guest_base_id "$guest_base_id" --arg manifest_sha "$manifest_sha" '
	.guest_bases == [{
		guest_base_id: $guest_base_id,
		os: "ubuntu",
		os_version: "26.04",
		architecture: "amd64",
		manifest_url: "https://github.com/yeetrun/yeet-vm-images/releases/download/guest-ubuntu-26.04-amd64-v1/guest-manifest.json",
		manifest_sha256: $manifest_sha
	}] and
	.channels["ubuntu-26.04-amd64"].candidate == {guest_base_id: $guest_base_id, manifest_sha256: $manifest_sha} and
	.channels["ubuntu-26.04-amd64"].stable == null
' "$tmp_dir/guest-catalog.json" >/dev/null

"$repo_root/scripts/verify-component-catalogs.sh" \
	"$repo_root/catalog.json" \
	"$tmp_dir/guest-catalog.json" \
	"$repo_root/kernel-catalog.json"

for forbidden in \
	'firecracker_version:' \
	'kernel_version:' \
	'upstream_kernel_version:' \
	'kernel_source_url:' \
	'kernel_source_sha256:' \
	'kernel_config_url:' \
	'overwrite_release:' \
	'publish_latest_alias:' \
	'latest_alias:' \
	'build-linux-kernel.sh' \
	'download-kernel-release.sh' \
	'YEET_VM_KERNEL_PATH' \
	'FIRECRACKER_VERSION'
do
	if grep -Fq "$forbidden" "$workflow"; then
		echo "Ubuntu guest-base workflow still contains monolithic input or behavior: $forbidden" >&2
		exit 1
	fi
done

for required in \
	'guest_base_id:' \
	'yeet_ref:' \
	'kernel_release:' \
	'kernel_manifest_sha256:' \
	'zstd_level:' \
	'scripts/update-guest-catalog.sh' \
	'scripts/publish-guest-base-assets.sh' \
	'--channel candidate' \
	'actions/create-github-app-token@' \
	'environment: firecracker-runtime-promotion' \
	'gh pr create'
do
	grep -Fq -- "$required" "$workflow"
done
if grep -Fq 'peter-evans/create-pull-request@' "$workflow"; then
	echo "Ubuntu candidate promotion still relies on the organization-blocked Actions token" >&2
	exit 1
fi
for ignored in '.build-work/' 'dist/' 'yeet-src/'; do
	grep -Fxq -- "$ignored" "$repo_root/.gitignore"
done

for forbidden in \
	'Downloading Firecracker' \
	'firecracker_tgz=' \
	'firecracker_url=' \
	'install -m 0755 "$fc_dir/firecracker' \
	'install -m 0755 "$fc_dir/jailer' \
	'install -m 0644 "$work_dir/vmlinux" "$out_dir/vmlinux"' \
	'kernel.config" "$out_dir/kernel.config"'
do
	if grep -Fq "$forbidden" "$builder"; then
		echo "Ubuntu guest-base builder still emits a host artifact: $forbidden" >&2
		exit 1
	fi
done

grep -Fq 'guest-manifest.json' "$builder"
grep -Fq 'provenance.json' "$builder"
grep -Fq 'rootfs.ext4.zst' "$builder"

printf '%s\n' 'Ubuntu component guest-base tests passed'
