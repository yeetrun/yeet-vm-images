#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

renderer="$repo_root/scripts/render-kernel-manifest.sh"
updater="$repo_root/scripts/update-kernel-catalog.sh"

test -x "$renderer"
test -x "$updater"

printf 'kernel payload\n' >"$tmp_dir/vmlinux"
printf 'kernel config\n' >"$tmp_dir/kernel.config"
vmlinux_sha="$(sha256sum "$tmp_dir/vmlinux" | awk '{ print $1 }')"
config_sha="$(sha256sum "$tmp_dir/kernel.config" | awk '{ print $1 }')"
source_commit="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
workflow_run_url="https://github.com/yeetrun/yeet-vm-images/actions/runs/123456790"
kernel_id="kernel-linux-7.1.1-yeet-v1"

"$renderer" \
	--kernel-id "$kernel_id" \
	--upstream-version 7.1.1 \
	--packaging-revision 1 \
	--architecture amd64 \
	--vmlinux "$tmp_dir/vmlinux" \
	--config "$tmp_dir/kernel.config" \
	--source-commit "$source_commit" \
	--workflow-run-url "$workflow_run_url" \
	--out "$tmp_dir/kernel-manifest.json"

jq -e \
	--arg kernel_id "$kernel_id" \
	--arg vmlinux_sha "$vmlinux_sha" \
	--arg config_sha "$config_sha" \
	--arg source_commit "$source_commit" \
	--arg workflow_run_url "$workflow_run_url" '
	keys == ["architecture", "config", "guest_packages", "kernel_id", "packaging_revision", "provenance", "schema_version", "upstream_version", "vmlinux"] and
	.schema_version == 1 and
	.kernel_id == $kernel_id and
	.upstream_version == "7.1.1" and
	.packaging_revision == 1 and
	.architecture == "amd64" and
	.vmlinux == {
		url: "https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.1-yeet-v1/vmlinux",
		sha256: $vmlinux_sha
	} and
	.config == {
		url: "https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.1-yeet-v1/kernel.config",
		sha256: $config_sha
	} and
	.guest_packages == {
		catalog_url: "https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-packages/catalog.json",
		selector_schema_version: 2,
		release_id: $kernel_id
	} and
	.provenance == {source_commit: $source_commit, workflow_run_url: $workflow_run_url}
' "$tmp_dir/kernel-manifest.json" >/dev/null

manifest_sha="$(sha256sum "$tmp_dir/kernel-manifest.json" | awk '{ print $1 }')"
"$updater" \
	--manifest "$tmp_dir/kernel-manifest.json" \
	--manifest-sha256 "$manifest_sha" \
	--channel stable \
	--catalog-in "$repo_root/kernel-catalog.json" \
	--catalog-out "$tmp_dir/kernel-catalog.json"

jq -e --arg kernel_id "$kernel_id" --arg manifest_sha "$manifest_sha" \
	--slurpfile original "$repo_root/kernel-catalog.json" '
	. as $updated |
	([.kernels[] | select(. == {
		kernel_id: $kernel_id,
		upstream_version: "7.1.1",
		packaging_revision: 1,
		architecture: "amd64",
		manifest_url: "https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.1-yeet-v1/kernel-manifest.json",
		manifest_sha256: $manifest_sha
	})] | length) == 1 and
	($updated.kernels | length) == (($original[0].kernels | length) + 1) and
	($original[0].kernels - $updated.kernels | length) == 0 and
	.channels.amd64.stable == {kernel_id: $kernel_id, manifest_sha256: $manifest_sha} and
	.channels.amd64.candidate == null
' "$tmp_dir/kernel-catalog.json" >/dev/null

"$repo_root/scripts/verify-component-catalogs.sh" \
	"$repo_root/catalog.json" \
	"$repo_root/guest-catalog.json" \
	"$tmp_dir/kernel-catalog.json"

printf '%s\n' 'kernel component release tests passed'
