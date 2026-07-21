#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root_catalog="${1:-$repo_root/catalog.json}"
guest_catalog="${2:-$repo_root/guest-catalog.json}"
kernel_catalog="${3:-$repo_root/kernel-catalog.json}"

command -v jq >/dev/null 2>&1 || { echo "missing required command: jq" >&2; exit 1; }
for path in "$root_catalog" "$guest_catalog" "$kernel_catalog"; do
	[ -f "$path" ] || { echo "component catalog does not exist: $path" >&2; exit 1; }
done

jq -e '
  .schema_version == 1 and
  (.images | type == "array") and
  (.component_catalogs | keys == ["guest_bases", "kernels", "runtimes"]) and
  .component_catalogs.guest_bases == "https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/guest-catalog.json" and
  .component_catalogs.kernels == "https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-catalog.json" and
  .component_catalogs.runtimes == "https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/runtime-catalog.json"
' "$root_catalog" >/dev/null || { echo "invalid component catalog references: $root_catalog" >&2; exit 1; }

jq -e '
  def sha256: type == "string" and test("^[0-9a-f]{64}$");
  def guest_id: type == "string" and test("^guest-(ubuntu|nixos)-[0-9]+[.][0-9]+-amd64-v[1-9][0-9]*$");
  def pointer: type == "object" and (keys == ["guest_base_id", "manifest_sha256"]) and (.guest_base_id | guest_id) and (.manifest_sha256 | sha256);
  def entry:
    type == "object" and
    (keys == ["architecture", "guest_base_id", "manifest_sha256", "manifest_url", "os", "os_version"]) and
    (.guest_base_id | guest_id) and
    (.os == "ubuntu" or .os == "nixos") and
    (.os_version | type == "string" and test("^[0-9]+[.][0-9]+$")) and
    .architecture == "amd64" and
    .guest_base_id == "guest-\(.os)-\(.os_version)-\(.architecture)-" + (.guest_base_id | capture("-(?<revision>v[1-9][0-9]*)$").revision) and
    .manifest_url == "https://github.com/yeetrun/yeet-vm-images/releases/download/\(.guest_base_id)/guest-manifest.json" and
    (.manifest_sha256 | sha256);
  def resolves($entries; $pointer):
    $pointer == null or (($pointer | pointer) and ([$entries[] | select(.guest_base_id == $pointer.guest_base_id and .manifest_sha256 == $pointer.manifest_sha256)] | length == 1));
  . as $catalog |
  (keys == ["channels", "guest_bases", "schema_version"]) and
  .schema_version == 1 and
  (.guest_bases | type == "array" and all(.[]; entry)) and
  ([.guest_bases[].guest_base_id] == ([.guest_bases[].guest_base_id] | sort)) and
  (([.guest_bases[].guest_base_id] | unique | length) == (.guest_bases | length)) and
  (.channels | keys == ["nixos-26.05-amd64", "ubuntu-26.04-amd64"]) and
  all(.channels | to_entries[];
    . as $channel |
    .value.stable as $stable |
    .value.candidate as $candidate |
    (.value | keys == ["candidate", "stable"]) and
    resolves($catalog.guest_bases; $stable) and
    resolves($catalog.guest_bases; $candidate) and
    all([$stable, $candidate][];
      . == null or ((.guest_base_id | sub("^guest-"; "") | sub("-v[1-9][0-9]*$"; "")) == $channel.key)))
' "$guest_catalog" >/dev/null || { echo "invalid guest component catalog: $guest_catalog" >&2; exit 1; }

jq -e '
  def sha256: type == "string" and test("^[0-9a-f]{64}$");
  def kernel_id: type == "string" and test("^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$");
  def pointer: type == "object" and (keys == ["kernel_id", "manifest_sha256"]) and (.kernel_id | kernel_id) and (.manifest_sha256 | sha256);
  def entry:
    type == "object" and
    (keys == ["architecture", "kernel_id", "manifest_sha256", "manifest_url", "packaging_revision", "upstream_version"]) and
    (.kernel_id | kernel_id) and
    (.upstream_version | type == "string" and test("^[0-9]+[.][0-9]+([.][0-9]+)*$")) and
    (.packaging_revision | type == "number" and floor == . and . > 0) and
    .architecture == "amd64" and
    .kernel_id == "kernel-linux-\(.upstream_version)-yeet-v\(.packaging_revision)" and
    .manifest_url == "https://github.com/yeetrun/yeet-vm-images/releases/download/\(.kernel_id)/kernel-manifest.json" and
    (.manifest_sha256 | sha256);
  def resolves($entries; $pointer):
    $pointer == null or (($pointer | pointer) and ([$entries[] | select(.kernel_id == $pointer.kernel_id and .manifest_sha256 == $pointer.manifest_sha256)] | length == 1));
  . as $catalog |
  .channels.amd64.stable as $stable |
  .channels.amd64.candidate as $candidate |
  (keys == ["channels", "kernels", "schema_version"]) and
  .schema_version == 1 and
  (.kernels | type == "array" and all(.[]; entry)) and
  ([.kernels[].kernel_id] == ([.kernels[].kernel_id] | sort)) and
  (([.kernels[].kernel_id] | unique | length) == (.kernels | length)) and
  (.channels | keys == ["amd64"]) and
  (.channels.amd64 | keys == ["candidate", "stable"]) and
  resolves($catalog.kernels; $stable) and
  resolves($catalog.kernels; $candidate)
' "$kernel_catalog" >/dev/null || { echo "invalid kernel component catalog: $kernel_catalog" >&2; exit 1; }
