#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$repo_root/scripts/build-ubuntu-26.04.sh"
workflow="$repo_root/.github/workflows/build-ubuntu-26.04.yml"

assert_contains() {
	local file="$1"
	local needle="$2"
	if ! grep -Fq "$needle" "$file"; then
		echo "$file does not contain: $needle" >&2
		exit 1
	fi
}

assert_contains "$builder" "/etc/needrestart/conf.d/99-yeet-vm-kernel.conf"
assert_contains "$builder" '$nrconf{kernelhints} = 0;'
assert_contains "$workflow" "debugfs -R 'stat /etc/needrestart/conf.d/99-yeet-vm-kernel.conf'"
assert_contains "$workflow" 'debugfs_cat /etc/needrestart/conf.d/99-yeet-vm-kernel.conf | grep -q'
