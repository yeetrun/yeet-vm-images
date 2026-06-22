#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

bin_dir="$tmp_dir/bin"
out_dir="$tmp_dir/out"
kernel_out_dir="$tmp_dir/kernel-out"
mkdir -p "$bin_dir" "$out_dir" "$kernel_out_dir"

for asset in manifest.json vmlinux rootfs.ext4.zst firecracker kernel.config checksums.txt; do
	printf '%s\n' "$asset payload" >"$out_dir/$asset"
done
for asset in vmlinux kernel.config kernel-manifest.json kernel-checksums.txt; do
	printf '%s\n' "$asset payload" >"$kernel_out_dir/$asset"
done
printf 'release notes\n' >"$out_dir/release-notes.md"

cat >"$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${YEET_FAKE_GH_LOG:?}"
if [ "$1" != "release" ]; then
	echo "unexpected gh command: $*" >&2
	exit 1
fi
shift

case "$1" in
	create)
		shift
		printf 'create %s\n' "$*" >>"$log"
		;;
	upload)
		shift
		tag="$1"
		file="$2"
		printf 'upload %s %s\n' "$tag" "$(basename "$file")" >>"$log"
		if [ "${YEET_FAKE_GH_FAIL_UPLOAD:-}" = "$(basename "$file")" ]; then
			exit 42
		fi
		;;
	edit)
		shift
		printf 'edit %s\n' "$*" >>"$log"
		;;
	delete)
		shift
		printf 'delete %s\n' "$*" >>"$log"
		;;
	*)
		echo "unexpected gh release command: $*" >&2
		exit 1
		;;
esac
EOF
chmod +x "$bin_dir/gh"

assert_log() {
	local expected="$1"
	local actual
	actual="$(cat "$YEET_FAKE_GH_LOG")"
	if [ "$actual" != "$expected" ]; then
		echo "unexpected gh call log" >&2
		echo "expected:" >&2
		printf '%s\n' "$expected" >&2
		echo "actual:" >&2
		printf '%s\n' "$actual" >&2
		exit 1
	fi
}

YEET_FAKE_GH_LOG="$tmp_dir/success.log"
export YEET_FAKE_GH_LOG
PATH="$bin_dir:$PATH" "$repo_root/scripts/publish-github-release-assets.sh" \
	test-tag \
	test-title \
	abc123 \
	"$out_dir/release-notes.md" \
	"$out_dir"

assert_log "create test-tag --draft --target abc123 --title test-title --notes-file $out_dir/release-notes.md
upload test-tag rootfs.ext4.zst
upload test-tag manifest.json
upload test-tag vmlinux
upload test-tag firecracker
upload test-tag kernel.config
upload test-tag checksums.txt
edit test-tag --draft=false"

YEET_FAKE_GH_LOG="$tmp_dir/kernel-success.log"
export YEET_FAKE_GH_LOG
PATH="$bin_dir:$PATH" "$repo_root/scripts/publish-kernel-release-assets.sh" \
	kernel-linux-7.1.1-yeet-v1 \
	kernel-linux-7.1.1-yeet-v1 \
	abc123 \
	"$out_dir/release-notes.md" \
	"$kernel_out_dir"

assert_log "create kernel-linux-7.1.1-yeet-v1 --draft --target abc123 --title kernel-linux-7.1.1-yeet-v1 --notes-file $out_dir/release-notes.md
upload kernel-linux-7.1.1-yeet-v1 vmlinux
upload kernel-linux-7.1.1-yeet-v1 kernel.config
upload kernel-linux-7.1.1-yeet-v1 kernel-manifest.json
upload kernel-linux-7.1.1-yeet-v1 kernel-checksums.txt
edit kernel-linux-7.1.1-yeet-v1 --draft=false"

YEET_FAKE_GH_LOG="$tmp_dir/failure.log"
YEET_FAKE_GH_FAIL_UPLOAD="rootfs.ext4.zst"
export YEET_FAKE_GH_LOG YEET_FAKE_GH_FAIL_UPLOAD
if PATH="$bin_dir:$PATH" "$repo_root/scripts/publish-github-release-assets.sh" \
	test-tag \
	test-title \
	abc123 \
	"$out_dir/release-notes.md" \
	"$out_dir"; then
	echo "publish helper succeeded despite a failed rootfs upload" >&2
	exit 1
fi

assert_log "create test-tag --draft --target abc123 --title test-title --notes-file $out_dir/release-notes.md
upload test-tag rootfs.ext4.zst
delete test-tag --yes"

YEET_FAKE_GH_LOG="$tmp_dir/kernel-failure.log"
YEET_FAKE_GH_FAIL_UPLOAD="kernel.config"
export YEET_FAKE_GH_LOG YEET_FAKE_GH_FAIL_UPLOAD
if PATH="$bin_dir:$PATH" "$repo_root/scripts/publish-kernel-release-assets.sh" \
	kernel-linux-7.1.1-yeet-v1 \
	kernel-linux-7.1.1-yeet-v1 \
	abc123 \
	"$out_dir/release-notes.md" \
	"$kernel_out_dir"; then
	echo "kernel publish helper succeeded despite a failed kernel.config upload" >&2
	exit 1
fi

assert_log "create kernel-linux-7.1.1-yeet-v1 --draft --target abc123 --title kernel-linux-7.1.1-yeet-v1 --notes-file $out_dir/release-notes.md
upload kernel-linux-7.1.1-yeet-v1 vmlinux
upload kernel-linux-7.1.1-yeet-v1 kernel.config
delete kernel-linux-7.1.1-yeet-v1 --yes"
unset YEET_FAKE_GH_FAIL_UPLOAD
