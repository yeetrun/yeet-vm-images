#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/scripts/wait-for-public-kernel-catalog.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

release_id="kernel-linux-7.1.5-yeet-v1"
manifest_sha256="4ea74629cb1e9cb5287791d0e6fb286a45b9632b89ba0bb465f616126d103822"
other_manifest_sha256="05c70cc78db192ab8e1b88a2dd1a4b3e1401a243f5b05bf75708b2ed2cb44a9b"

jq -n \
	--arg release "$release_id" \
	--arg manifest "$manifest_sha256" '
	{
		schema_version: 1,
		kernels: [{kernel_id: $release, manifest_sha256: $manifest}],
		channels: {amd64: {stable: {kernel_id: $release, manifest_sha256: $manifest}}}
	}
' >"$tmp_dir/matching.json"

jq -n \
	--arg release "$release_id" \
	--arg manifest "$manifest_sha256" \
	--arg other_manifest "$other_manifest_sha256" '
	{
		schema_version: 1,
		kernels: [{kernel_id: $release, manifest_sha256: $manifest}],
		channels: {amd64: {stable: {kernel_id: $release, manifest_sha256: $other_manifest}}}
	}
' >"$tmp_dir/mismatched.json"

YEET_KERNEL_CATALOG_SETTLE_SECONDS=0 \
	YEET_KERNEL_CATALOG_ATTEMPTS=1 \
	YEET_KERNEL_CATALOG_RETRY_SECONDS=0 \
	"$verifier" "file://$tmp_dir/matching.json" "$release_id" "$manifest_sha256"

mkdir "$tmp_dir/bin"
cat >"$tmp_dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$YEET_TEST_SLEEP_LOG"
EOF
chmod +x "$tmp_dir/bin/sleep"
sleep_log="$tmp_dir/sleep.log"
PATH="$tmp_dir/bin:$PATH" \
	YEET_TEST_SLEEP_LOG="$sleep_log" \
	YEET_KERNEL_CATALOG_SETTLE_SECONDS=7 \
	YEET_KERNEL_CATALOG_ATTEMPTS=1 \
	YEET_KERNEL_CATALOG_RETRY_SECONDS=0 \
	"$verifier" "file://$tmp_dir/matching.json" "$release_id" "$manifest_sha256"
if [ "$(cat "$sleep_log")" != $'7\n7' ]; then
	echo "public catalog verifier did not drain a full cache lifetime after first observing the new catalog" >&2
	exit 1
fi

if YEET_KERNEL_CATALOG_SETTLE_SECONDS=0 \
	YEET_KERNEL_CATALOG_ATTEMPTS=1 \
	YEET_KERNEL_CATALOG_RETRY_SECONDS=0 \
	"$verifier" "file://$tmp_dir/mismatched.json" "$release_id" "$manifest_sha256" >/dev/null 2>&1; then
	echo "public catalog verifier accepted a mismatched stable channel" >&2
	exit 1
fi

if YEET_KERNEL_CATALOG_SETTLE_SECONDS=0 \
	YEET_KERNEL_CATALOG_ATTEMPTS=1 \
	YEET_KERNEL_CATALOG_RETRY_SECONDS=0 \
	"$verifier" "file://$tmp_dir/matching.json" "$release_id" invalid >/dev/null 2>&1; then
	echo "public catalog verifier accepted an invalid manifest digest" >&2
	exit 1
fi
