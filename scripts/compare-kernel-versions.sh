#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 <left-version> <right-version>" >&2
	exit 2
}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required command: $1" >&2
		exit 1
	fi
}

if [ "$#" -ne 2 ]; then
	usage
fi

require awk

left="$1"
right="$2"

awk -v left="$left" -v right="$right" '
  function valid(version) {
    return version ~ /^[0-9]+([.][0-9]+)*$/
  }

  BEGIN {
    if (!valid(left)) {
      print "invalid kernel version: " left >"/dev/stderr"
      exit 2
    }
    if (!valid(right)) {
      print "invalid kernel version: " right >"/dev/stderr"
      exit 2
    }

    left_count = split(left, left_parts, ".")
    right_count = split(right, right_parts, ".")
    count = left_count > right_count ? left_count : right_count
    for (i = 1; i <= count; i++) {
      left_part = i in left_parts ? left_parts[i] + 0 : 0
      right_part = i in right_parts ? right_parts[i] + 0 : 0
      if (left_part > right_part) {
        print 1
        exit
      }
      if (left_part < right_part) {
        print -1
        exit
      }
    }
    print 0
  }
'
