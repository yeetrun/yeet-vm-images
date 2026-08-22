#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

verifier="$repo_root/scripts/verify-kernel-boot-policy.sh"
build_script="$repo_root/scripts/build-linux-kernel.sh"
workflow="$repo_root/.github/workflows/build-kernel.yml"

fail() {
	echo "kernel boot policy test failed: $*" >&2
	exit 1
}

assert_fails() {
	if "$@" >/dev/null 2>&1; then
		fail "command unexpectedly succeeded: $*"
	fi
}

[ -x "$verifier" ] || fail "missing executable verifier: $verifier"

cat >"$tmp_dir/valid.config" <<'EOF'
# CONFIG_SERIO_I8042 is not set
# CONFIG_KEYBOARD_ATKBD is not set
EOF
"$verifier" "$tmp_dir/valid.config"

cat >"$tmp_dir/i8042-enabled.config" <<'EOF'
CONFIG_SERIO_I8042=y
# CONFIG_KEYBOARD_ATKBD is not set
EOF
assert_fails "$verifier" "$tmp_dir/i8042-enabled.config"

cat >"$tmp_dir/atkbd-enabled.config" <<'EOF'
# CONFIG_SERIO_I8042 is not set
CONFIG_KEYBOARD_ATKBD=y
EOF
assert_fails "$verifier" "$tmp_dir/atkbd-enabled.config"

printf '%s\n' '# CONFIG_SERIO_I8042 is not set' >"$tmp_dir/missing-atkbd.config"
assert_fails "$verifier" "$tmp_dir/missing-atkbd.config"

grep -Fq -- '--disable SERIO_I8042' "$build_script" || fail "kernel build does not disable SERIO_I8042"
grep -Fq -- '--disable KEYBOARD_ATKBD' "$build_script" || fail "kernel build does not disable KEYBOARD_ATKBD"
grep -Fq 'verify-kernel-boot-policy.sh "$KERNEL_OUT_DIR/kernel.config"' "$workflow" || fail "publish workflow does not verify the built kernel config"

echo "kernel boot policy tests passed"
