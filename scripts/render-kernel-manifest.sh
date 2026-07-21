#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 --kernel-id <id> --upstream-version <version> --packaging-revision <revision> --architecture amd64 --vmlinux <path> --config <path> --source-commit <sha> --workflow-run-url <url> --out <path>" >&2
	exit 2
}

kernel_id=""
upstream_version=""
packaging_revision=""
architecture=""
vmlinux=""
config=""
source_commit=""
workflow_run_url=""
out=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--kernel-id) kernel_id="${2:-}"; shift 2 ;;
		--upstream-version) upstream_version="${2:-}"; shift 2 ;;
		--packaging-revision) packaging_revision="${2:-}"; shift 2 ;;
		--architecture) architecture="${2:-}"; shift 2 ;;
		--vmlinux) vmlinux="${2:-}"; shift 2 ;;
		--config) config="${2:-}"; shift 2 ;;
		--source-commit) source_commit="${2:-}"; shift 2 ;;
		--workflow-run-url) workflow_run_url="${2:-}"; shift 2 ;;
		--out) out="${2:-}"; shift 2 ;;
		*) usage ;;
	esac
done

for value in kernel_id upstream_version packaging_revision architecture vmlinux config source_commit workflow_run_url out; do
	[ -n "${!value}" ] || usage
done
for cmd in awk jq mkdir sha256sum; do
	command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

[[ "$upstream_version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)*$ ]] || { echo "invalid upstream kernel version: $upstream_version" >&2; exit 1; }
[[ "$packaging_revision" =~ ^[1-9][0-9]*$ ]] || { echo "invalid packaging revision: $packaging_revision" >&2; exit 1; }
[ "$kernel_id" = "kernel-linux-${upstream_version}-yeet-v${packaging_revision}" ] || { echo "kernel ID does not match version and packaging revision" >&2; exit 1; }
[ "$architecture" = "amd64" ] || { echo "unsupported kernel architecture: $architecture" >&2; exit 1; }
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid source commit: $source_commit" >&2; exit 1; }
[[ "$workflow_run_url" =~ ^https://github[.]com/yeetrun/yeet-vm-images/actions/runs/[1-9][0-9]*$ ]] || { echo "invalid workflow run URL: $workflow_run_url" >&2; exit 1; }
[ -s "$vmlinux" ] || { echo "vmlinux is missing or empty: $vmlinux" >&2; exit 1; }
[ -s "$config" ] || { echo "kernel config is missing or empty: $config" >&2; exit 1; }

vmlinux_sha="$(sha256sum "$vmlinux" | awk '{ print $1 }')"
config_sha="$(sha256sum "$config" | awk '{ print $1 }')"
asset_base="https://github.com/yeetrun/yeet-vm-images/releases/download/${kernel_id}"
mkdir -p "$(dirname "$out")"

jq -n \
	--arg kernel_id "$kernel_id" \
	--arg upstream_version "$upstream_version" \
	--argjson packaging_revision "$packaging_revision" \
	--arg architecture "$architecture" \
	--arg asset_base "$asset_base" \
	--arg vmlinux_sha "$vmlinux_sha" \
	--arg config_sha "$config_sha" \
	--arg source_commit "$source_commit" \
	--arg workflow_run_url "$workflow_run_url" '
	{
		schema_version: 1,
		kernel_id: $kernel_id,
		upstream_version: $upstream_version,
		packaging_revision: $packaging_revision,
		architecture: $architecture,
		vmlinux: {url: ($asset_base + "/vmlinux"), sha256: $vmlinux_sha},
		config: {url: ($asset_base + "/kernel.config"), sha256: $config_sha},
		guest_packages: {
			catalog_url: "https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-packages/catalog.json",
			selector_schema_version: 2,
			release_id: $kernel_id
		},
		provenance: {source_commit: $source_commit, workflow_run_url: $workflow_run_url}
	}' >"$out"
