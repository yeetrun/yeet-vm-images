#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "usage: $0 <kernel-config>" >&2
	exit 2
fi

config="$1"
[ -r "$config" ] || { echo "kernel config is not readable: $config" >&2; exit 1; }

for key in CONFIG_SERIO_I8042 CONFIG_KEYBOARD_ATKBD; do
	if ! grep -Eq "^(# ${key} is not set|${key}=n)$" "$config"; then
		echo "kernel boot policy requires $key to be disabled" >&2
		exit 1
	fi
done

echo "kernel boot policy verified"
