#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
script_dir="${script_source%/*}"
if [ "$script_dir" = "$script_source" ]; then
	script_dir="."
fi
repo_root="$(cd "$script_dir/.." && pwd)"
catalog="$repo_root/catalog.json"

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

for cmd in curl jq; do
	require "$cmd"
done

jq -e '
  def supported_capabilities: ["guest_agent", "guest_init", "rsync"];
  def payload_version_prefix:
    (.payload | sub("^vm://"; "") | gsub("/"; "-")) + "-" + .architecture + "-";
  .schema_version == 1 and
  (.images | type == "array") and
  (.images | length > 0) and
  all(.images[]; (
    (.payload | type == "string" and startswith("vm://")) and
    (.name | type == "string" and length > 0) and
    (.architecture == "amd64") and
    (.manifest_url | type == "string" and startswith("https://github.com/yeetrun/yeet-vm-images/releases/download/")) and
    (.version_prefix | type == "string" and test("^[a-z0-9]+-[0-9]+[.][0-9]+-amd64-$")) and
    (.version_prefix == payload_version_prefix) and
    (.default_user | type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$")) and
    (.metadata_driver == "ubuntu" or .metadata_driver == "nixos") and
    (.capabilities | type == "array" and sort == supported_capabilities)
  ))
' "$catalog" >/dev/null

duplicates="$(
	jq -r '.images[].payload' "$catalog" | sort | uniq -d
)"
if [ -n "$duplicates" ]; then
	echo "duplicate catalog payload(s): $duplicates" >&2
	exit 1
fi

for payload in "vm://ubuntu/26.04" "vm://nixos/26.05"; do
	if ! jq -e --arg payload "$payload" '[.images[].payload] | index($payload) != null' "$catalog" >/dev/null; then
		echo "missing required catalog payload: $payload" >&2
		exit 1
	fi
done

default_count="$(jq '[.images[] | select(.default == true)] | length' "$catalog")"
if [ "$default_count" -gt 1 ]; then
	echo "at most one catalog image may be marked default" >&2
	exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

jq -c '.images[]' "$catalog" | while IFS= read -r image; do
	payload="$(jq -r '.payload' <<<"$image")"
	manifest_url="$(jq -r '.manifest_url' <<<"$image")"
	version_prefix="$(jq -r '.version_prefix' <<<"$image")"
	manifest="$tmp_dir/$(tr '/:' '__' <<<"$payload").json"
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "$manifest_url" -o "$manifest"
	version="$(jq -r '.version // empty' "$manifest")"
	version_prefix_regex="${version_prefix//./\\.}"
	if ! jq -e --arg version_re "^${version_prefix_regex}v[0-9]+$" '
	  (.version | type == "string") and
	  (.version | test($version_re))
	' "$manifest" >/dev/null; then
		echo "$payload manifest version $version does not match prefix $version_prefix" >&2
		exit 1
	fi
	jq -e '
	  (.guest_init == "/usr/local/lib/yeet-vm/yeet-init") and
	  (.guest_agent == "/usr/local/lib/yeet-vm/yeet-agent") and
	  (.guest_agent_sha256 | test("^[0-9a-f]{64}$")) and
	  (.checksums | type == "object")
	' "$manifest" >/dev/null
done
