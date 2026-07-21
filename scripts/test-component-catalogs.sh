#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
fail() { echo "component catalog test failed: $*" >&2; exit 1; }

schema_validator="${CHECK_JSONSCHEMA:-}"
if [ -z "$schema_validator" ]; then
	if command -v check-jsonschema >/dev/null 2>&1; then
		schema_validator="$(command -v check-jsonschema)"
	elif command -v mise >/dev/null 2>&1; then
		schema_validator="$(mise which check-jsonschema 2>/dev/null || true)"
	fi
fi
[ -x "$schema_validator" ] || fail "missing check-jsonschema"

guest_schema="$repo_root/schemas/guest-base-manifest.schema.json"
guest_catalog_schema="$repo_root/schemas/guest-catalog.schema.json"
kernel_schema="$repo_root/schemas/kernel-manifest.schema.json"
kernel_catalog_schema="$repo_root/schemas/kernel-catalog.schema.json"
guest_manifest="$repo_root/scripts/testdata/guest-manifest-valid.json"
kernel_manifest="$repo_root/scripts/testdata/kernel-manifest-valid.json"
verifier="$repo_root/scripts/verify-component-catalogs.sh"
guest_renderer="$repo_root/scripts/render-guest-manifest.sh"
guest_updater="$repo_root/scripts/update-guest-catalog.sh"

for path in "$guest_schema" "$guest_catalog_schema" "$kernel_schema" "$kernel_catalog_schema" "$guest_manifest" "$kernel_manifest" "$verifier" "$guest_renderer" "$guest_updater"; do
	[ -e "$path" ] || fail "missing contract artifact $path"
done
for helper in "$guest_renderer" "$guest_updater"; do
	[ -x "$helper" ] || fail "component helper is not executable: $helper"
done

"$schema_validator" --check-metaschema "$guest_schema" "$guest_catalog_schema" "$kernel_schema" "$kernel_catalog_schema" >/dev/null
"$schema_validator" --schemafile "$guest_schema" "$guest_manifest" >/dev/null
"$schema_validator" --schemafile "$kernel_schema" "$kernel_manifest" >/dev/null
"$schema_validator" --schemafile "$guest_catalog_schema" "$repo_root/guest-catalog.json" >/dev/null
"$schema_validator" --schemafile "$kernel_catalog_schema" "$repo_root/kernel-catalog.json" >/dev/null
"$verifier"

guest_filter='
  . as $manifest |
  (.guest_base_id | capture("^guest-(?<os>ubuntu|nixos)-(?<version>[0-9]+[.][0-9]+)-(?<architecture>amd64)-v[1-9][0-9]*$") as $id |
    $manifest.os == $id.os and $manifest.os_version == $id.version and $manifest.architecture == $id.architecture) and
  .rootfs.url == "https://github.com/yeetrun/yeet-vm-images/releases/download/\(.guest_base_id)/rootfs.ext4.zst" and
  ([.. | objects | keys[]] | all(. != "firecracker" and . != "jailer" and . != "vmlinux"))'
kernel_filter='
  . as $manifest |
  (.kernel_id | capture("^kernel-linux-(?<version>[0-9]+[.][0-9]+([.][0-9]+)*)-yeet-v(?<revision>[1-9][0-9]*)$") as $id |
    $manifest.upstream_version == $id.version and ($manifest.packaging_revision | tostring) == $id.revision) and
  .vmlinux.url == "https://github.com/yeetrun/yeet-vm-images/releases/download/\(.kernel_id)/vmlinux" and
  .config.url == "https://github.com/yeetrun/yeet-vm-images/releases/download/\(.kernel_id)/kernel.config" and
  .guest_packages.release_id == .kernel_id and
  .guest_packages.selector_schema_version == 2'
jq -e "$guest_filter" "$guest_manifest" >/dev/null
jq -e "$kernel_filter" "$kernel_manifest" >/dev/null

jq '.firecracker = {"url":"https://example.invalid/firecracker"}' "$guest_manifest" >"$tmp_dir/guest-host-runtime.json"
if "$schema_validator" --schemafile "$guest_schema" "$tmp_dir/guest-host-runtime.json" >/dev/null 2>&1; then
	fail "guest schema accepted a host runtime payload"
fi
jq '.rootfs.url = "https://github.com/yeetrun/yeet-vm-images/releases/download/guest-ubuntu-26.04-amd64-v2/rootfs.ext4.zst"' "$guest_manifest" >"$tmp_dir/guest-wrong-release.json"
if jq -e "$guest_filter" "$tmp_dir/guest-wrong-release.json" >/dev/null 2>&1; then
	fail "guest cross-field validation accepted a mismatched release URL"
fi
jq '.vmlinux.extra = true' "$kernel_manifest" >"$tmp_dir/kernel-extra.json"
if "$schema_validator" --schemafile "$kernel_schema" "$tmp_dir/kernel-extra.json" >/dev/null 2>&1; then
	fail "kernel schema accepted an unknown payload property"
fi
jq '.guest_packages.release_id = "kernel-linux-7.1.2-yeet-v1"' "$kernel_manifest" >"$tmp_dir/kernel-wrong-release.json"
if jq -e "$kernel_filter" "$tmp_dir/kernel-wrong-release.json" >/dev/null 2>&1; then
	fail "kernel cross-field validation accepted mismatched selector metadata"
fi

guest_entry='{"guest_base_id":"guest-ubuntu-26.04-amd64-v1","os":"ubuntu","os_version":"26.04","architecture":"amd64","manifest_url":"https://github.com/yeetrun/yeet-vm-images/releases/download/guest-ubuntu-26.04-amd64-v1/guest-manifest.json","manifest_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
jq --argjson entry "$guest_entry" '.guest_bases = [$entry] | .channels["ubuntu-26.04-amd64"].candidate = {guest_base_id:$entry.guest_base_id, manifest_sha256:$entry.manifest_sha256}' "$repo_root/guest-catalog.json" >"$tmp_dir/guest-valid.json"
"$verifier" "$repo_root/catalog.json" "$tmp_dir/guest-valid.json" "$repo_root/kernel-catalog.json"
jq '.channels["ubuntu-26.04-amd64"].candidate.manifest_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$tmp_dir/guest-valid.json" >"$tmp_dir/guest-dangling.json"
if "$verifier" "$repo_root/catalog.json" "$tmp_dir/guest-dangling.json" "$repo_root/kernel-catalog.json" >/dev/null 2>&1; then
	fail "guest catalog accepted a dangling channel"
fi

kernel_entry_a='{"kernel_id":"kernel-linux-7.1.1-yeet-v1","upstream_version":"7.1.1","packaging_revision":1,"architecture":"amd64","manifest_url":"https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.1-yeet-v1/kernel-manifest.json","manifest_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
kernel_entry_b='{"kernel_id":"kernel-linux-7.1.0-yeet-v1","upstream_version":"7.1.0","packaging_revision":1,"architecture":"amd64","manifest_url":"https://github.com/yeetrun/yeet-vm-images/releases/download/kernel-linux-7.1.0-yeet-v1/kernel-manifest.json","manifest_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}'
jq --argjson a "$kernel_entry_a" --argjson b "$kernel_entry_b" '.kernels = [$a, $b]' "$repo_root/kernel-catalog.json" >"$tmp_dir/kernel-unsorted.json"
if "$verifier" "$repo_root/catalog.json" "$repo_root/guest-catalog.json" "$tmp_dir/kernel-unsorted.json" >/dev/null 2>&1; then
	fail "kernel catalog accepted unsorted entries"
fi

jq '.component_catalogs.kernels = "http://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-catalog.json"' "$repo_root/catalog.json" >"$tmp_dir/root-http.json"
if "$verifier" "$tmp_dir/root-http.json" "$repo_root/guest-catalog.json" "$repo_root/kernel-catalog.json" >/dev/null 2>&1; then
	fail "root catalog accepted a non-HTTPS component reference"
fi

jq -e '.schema_version == 1 and (.images | type == "array") and (.images | length > 0)' "$repo_root/catalog.json" >/dev/null
git -C "$repo_root" diff --check
echo "component catalog contract tests passed"
