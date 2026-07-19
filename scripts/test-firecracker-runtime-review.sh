#!/usr/bin/env bash
# shellcheck disable=SC2016 # Patterns intentionally match literal shell variables.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
require_source() {
	local group="$1" path="$2" pattern="$3"
	if ! grep -Eq -- "$pattern" "$path"; then
		echo "RED $group: missing production control: $pattern" >&2
		failures=$((failures + 1))
	fi
}
reject_source() {
	local group="$1" path="$2" pattern="$3"
	if grep -Eq -- "$pattern" "$path"; then
		echo "RED $group: unsafe production control remains: $pattern" >&2
		failures=$((failures + 1))
	fi
}

download="$repo_root/scripts/download-firecracker-release.sh"
build="$repo_root/scripts/build-firecracker-runtime.sh"
publish="$repo_root/scripts/publish-firecracker-runtime-assets.sh"
rename="$repo_root/scripts/atomic-rename-noreplace.py"
generator="$repo_root/scripts/testdata/generate-firecracker-runtime-fixtures.py"

require_source C1 "$download" '--proto-redir'
require_source C1 "$download" '--max-redirs'
require_source C1 "$download" '--max-filesize'
reject_source C2 "$download" '--archive'
reject_source C2 "$build" '--archive'
require_source C2 "$download" 'api[.]github[.]com/repos/firecracker-microvm/firecracker/releases/tags'
require_source C3 "$publish" 'firecracker-runtime-manifest[.]schema[.]json'
require_source C3 "$publish" 'runtime-checksums'
require_source C4 "$publish" 'refs/tags'
require_source C4 "$publish" 'api_call 201 POST "repos/\$repository/git/refs"'
require_source I1 "$download" 'GNUPGHOME'
reject_source I2 "$download" 'tar -x|tar --extract'
require_source I2 "$download" 'extract-firecracker-archive'
require_source I3 "$build" 'firecracker-runtime-policy[.]json'
require_source I4 "$build" 'GITHUB_ACTIONS'
reject_source I4 "$build" 'provenance-commit'
require_source I5 "$rename" 'st_uid'
require_source I5 "$rename" 'st_mode'
require_source I5 "$download" 'do not retry'
require_source I5 "$build" 'do not retry'
require_source I6 "$publish" 'releases/\$release_id'
reject_source I6 "$publish" 'If-Match'
require_source I6 "$publish" 'GITHUB_WORKFLOW_REF'
reject_source I6 "$publish" 'YEET_RUNTIME_PUBLISH_ENVIRONMENT'
reject_source I6 "$publish" 'YEET_RUNTIME_PUBLISH_CONCURRENCY_GROUP'
reject_source I6 "$publish" 'YEET_RUNTIME_PUBLISH_CANCEL_IN_PROGRESS'
reject_source I6 "$publish" 'YEET_RUNTIME_PUBLISH_CONTENTS_WRITE'
require_source I6 "$publish" 'GITHUB_JOB'
require_source I6 "$publish" 'YEET_RUNTIME_WORKFLOW_REPOSITORY'
require_source I6 "$publish" 'YEET_RUNTIME_WORKFLOW_FILE_PATH'
require_source I6 "$publish" 'YEET_RUNTIME_WORKFLOW_REF'
require_source I6 "$publish" 'YEET_RUNTIME_WORKFLOW_SHA'
require_source I6 "$publish" 'GH_TOKEN'
require_source I6 "$publish" 'unset GITHUB_TOKEN'
require_source M1 "$download" 'LC_ALL=C'
reject_source M2 "$generator" 'default=Path'
require_source M3 "$publish" 'next packaging revision'

if [ "$failures" -ne 0 ]; then
	echo "runtime review integrity controls missing: $failures" >&2
	exit 1
fi
echo "Firecracker runtime review controls verified"
