#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for file in \
	scripts/build-ubuntu-26.04.sh \
	scripts/build-nixos-26.05.sh \
	.github/workflows/build-ubuntu-26.04.yml \
	.github/workflows/build-nixos-26.05.yml
do
	for forbidden in \
		'firecracker_version:' \
		'FIRECRACKER_VERSION' \
		'install -m 0755 "$fc_dir/firecracker' \
		'install -m 0755 "$fc_dir/jailer' \
		'"firecracker": "firecracker"' \
		'"jailer": "jailer"'
	do
		if grep -Fq -- "$forbidden" "$repo_root/$file"; then
			echo "$file still couples a component guest base to host runtime artifact: $forbidden" >&2
			exit 1
		fi
	done
done

sync_workflow=.github/workflows/sync-latest-stable-kernel.yml
if grep -Fq -- 'firecracker_version:' "$repo_root/$sync_workflow"; then
	echo "$sync_workflow must not dispatch guest image builds or carry Firecracker image inputs" >&2
	exit 1
fi

echo "Component guest runtime boundary verified"
