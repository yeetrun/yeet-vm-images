#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions and README literals must remain unexpanded.
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$repo_root/.github/workflows/build-firecracker-runtime.yml"
sync="$repo_root/.github/workflows/sync-latest-stable-firecracker.yml"
readme="$repo_root/README.md"
published_verifier="$repo_root/scripts/verify-published-firecracker-runtime.sh"
published_test="$repo_root/scripts/test-published-firecracker-runtime.sh"
revision_resolver="$repo_root/scripts/resolve-firecracker-runtime-release.sh"
checkout_sha=df4cb1c069e1874edd31b4311f1884172cec0e10
app_token_sha=bcd2ba49218906704ab6c1aa796996da409d3eb1
initial_status="$(git -C "$repo_root" status --porcelain=v1)"
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

fail() {
	echo "Firecracker runtime workflow test failed: $*" >&2
	exit 1
}

require_file() {
	local path="$1"
	[ -f "$path" ] && [ ! -L "$path" ] || fail "missing regular file: ${path#"$repo_root/"}"
}

require_text() {
	local path="$1" text="$2" label="$3"
	grep -Fq -- "$text" "$path" || fail "$label"
}

reject_text() {
	local path="$1" text="$2" label="$3"
	if grep -Fq -- "$text" "$path"; then fail "$label"; fi
}

require_file "$build"
require_file "$sync"
require_file "$readme"
require_file "$published_verifier"
require_file "$published_test"

# Reusable interface and immutable candidate outputs.
require_text "$build" '  workflow_call:' "reusable workflow_call trigger is missing"
for input in upstream_version runtime_id allow_unsigned_tag allow_signer_rotation; do
	require_text "$build" "      $input:" "workflow_call input is missing: $input"
done
python3 - "$build" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"(?m)^      runtime_id:\n(?P<body>(?:^        .*\n)+)", text)
if not match or "required: true" not in match.group("body") or "default:" in match.group("body"):
    raise SystemExit("runtime_id workflow_call input must be required with no default")
PY
for output in runtime_id manifest_url manifest_sha256 release_url; do
	require_text "$build" "      $output:" "workflow_call output is missing: $output"
	require_text "$build" "jobs.publish-firecracker-runtime.outputs.$output" "workflow_call output is not wired to the publishing job: $output"
done
reject_text "$build" '  workflow_dispatch:' "reusable workflow must not be directly dispatched"

# The default token stays read-only. Writes use one protected serialized job.
require_text "$build" $'permissions:\n  contents: read' "reusable workflow default token is not contents:read"
require_text "$build" '  publish-firecracker-runtime:' "publishing job ID is missing"
require_text "$build" '      group: firecracker-runtime-publish' "publishing concurrency group is missing"
require_text "$build" '      cancel-in-progress: false' "publishing cancellation policy is missing"
require_text "$build" '    environment: firecracker-runtime-publish' "protected publishing environment is missing"
require_text "$build" '  approve-runtime-overrides:' "conditional override approval job is missing"
require_text "$build" '    environment: firecracker-runtime-overrides' "override approval environment is missing"
require_text "$build" 'inputs.allow_unsigned_tag || inputs.allow_signer_rotation' "override approval condition is missing"

# The repository-scoped App token has only the permissions needed by Task 3.
require_text "$build" "uses: actions/create-github-app-token@$app_token_sha" "App-token action pin is missing or incorrect"
require_text "$build" 'client-id: ${{ vars.YEET_RUNTIME_GITHUB_APP_CLIENT_ID }}' "App client ID is not environment-scoped"
require_text "$build" 'private-key: ${{ secrets.YEET_RUNTIME_GITHUB_APP_PRIVATE_KEY }}' "App private key is not environment-scoped"
require_text "$build" 'owner: yeetrun' "App token owner restriction is missing"
require_text "$build" 'repositories: yeet-vm-images' "App token repository restriction is missing"
require_text "$build" 'permission-administration: read' "App token Administration:read restriction is missing"
require_text "$build" 'permission-contents: write' "App token Contents:write restriction is missing"
require_text "$build" 'GH_TOKEN: ${{ steps.runtime-app-token.outputs.token }}' "App token is not wired to the publication step"
[ "$(grep -Fc 'steps.runtime-app-token.outputs.token' "$build")" = 1 ] || fail "App token is exposed outside the single publication step"
reject_text "$build" 'GH_TOKEN: ${{ github.token }}' "default token is used as a publication fallback"
reject_text "$build" 'GH_TOKEN: ${{ secrets.' "personal or generic secret token fallback remains"

# Called-workflow identity must match Task 3 exactly.
require_text "$build" 'YEET_RUNTIME_WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}' "called-workflow repository context is missing"
require_text "$build" 'YEET_RUNTIME_WORKFLOW_FILE_PATH: ${{ job.workflow_file_path }}' "called-workflow file-path context is missing"
require_text "$build" 'YEET_RUNTIME_WORKFLOW_REF: ${{ job.workflow_ref }}' "called-workflow ref context is missing"
require_text "$build" 'YEET_RUNTIME_WORKFLOW_SHA: ${{ job.workflow_sha }}' "called-workflow SHA context is missing"

# Revision resolution, exact bundle verification, publication, and integration event.
require_text "$build" 'scripts/resolve-firecracker-runtime-release.sh' "packaging revision is not resolved inside the publishing job"
reject_text "$build" '[ -n "$REQUESTED_RUNTIME_ID" ]' "serialized job still treats the runtime ID as optional"
require_text "$build" 'echo "$HOME/.local/bin" >>"$GITHUB_PATH"' "pinned check-jsonschema directory is not persisted for later steps"
require_text "$build" 'scripts/build-firecracker-runtime.sh' "runtime pair build is missing"
require_text "$build" 'scripts/verify-firecracker-runtime-bundle.py' "independent bundle verification is missing"
require_text "$build" 'scripts/publish-firecracker-runtime-assets.sh' "immutable candidate publisher is missing"
for asset in firecracker jailer runtime-manifest.json runtime-checksums.txt; do
	require_text "$build" "$asset" "exact bundle asset is missing from workflow verification: $asset"
done
reject_text "$build" 'repository_dispatch' "post-publication repository_dispatch remains"
reject_text "$build" '/dispatches' "post-publication dispatch API call remains"
reject_text "$build" 'event_type' "post-publication event payload remains"

# Only the scheduled/manual workflow may call the reusable workflow, and only locally.
require_text "$sync" '    - cron: "37 9 * * *"' "daily discovery schedule is missing or changed"
require_text "$sync" '  workflow_dispatch:' "manual discovery trigger is missing"
[ "$(grep -Fc '    - cron:' "$sync")" = 1 ] || fail "discovery workflow must contain exactly one schedule"
for extra_trigger in '  push:' '  pull_request:' '  repository_dispatch:' '  workflow_call:'; do
	reject_text "$sync" "$extra_trigger" "discovery workflow contains an unplanned trigger: $extra_trigger"
done
require_text "$sync" $'permissions:\n  contents: read' "discovery default token is not contents:read"
require_text "$sync" '  group: sync-latest-stable-firecracker' "discovery concurrency group is missing"
require_text "$sync" '  cancel-in-progress: false' "discovery cancellation policy is missing"
require_text "$sync" 'scripts/resolve-latest-firecracker.sh' "official stable release discovery is missing"
require_text "$sync" 'scripts/resolve-firecracker-runtime-release.sh' "existing candidate comparison is missing"
require_text "$sync" 'scripts/verify-published-firecracker-runtime.sh' "published candidate is not verified before no-op"
require_text "$sync" 'allocation="$(scripts/resolve-firecracker-runtime-release.sh "$upstream_version")"' "next revision is not allocated from all remote tag refs"
require_text "$sync" 'published="$(scripts/resolve-firecracker-runtime-release.sh "$upstream_version" "$published_tags")"' "published candidates are not resolved separately"
require_text "$sync" "jq -er '.upstream_version'" "discovery does not read the resolver's upstream_version field"
reject_text "$sync" "jq -er '.version'" "discovery reads a nonexistent resolver version field"
require_text "$sync" "runtime_id=\$runtime_id" "discovery does not expose the computed next runtime ID"
require_text "$sync" 'uses: ./.github/workflows/build-firecracker-runtime.yml' "exact local reusable-workflow call is missing"
reject_text "$sync" './.github/workflows/build-firecracker-runtime.yml@' "local reusable-workflow call contains a ref"
require_text "$sync" 'runtime_id: ${{ needs.discover.outputs.runtime_id }}' "replay-safe runtime ID is not passed to the serialized workflow"
require_text "$sync" 'Candidate already exists; no publication requested.' "verified no-op summary is missing"
require_text "$sync" 'DISCOVERY_RESULT: ${{ needs.discover.result }}' "summary does not distinguish discovery failure from a verified no-op"

validate_callers() {
	python3 - "$1" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
matches = []
for path in sorted(path for path in root.iterdir() if path.suffix in {".yml", ".yaml"}):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = re.match(r"\s*uses:\s*(\S+)\s*$", line)
        if match and "build-firecracker-runtime.yml" in match.group(1):
            matches.append((path.name, number, match.group(1)))
expected = [("sync-latest-stable-firecracker.yml", "./.github/workflows/build-firecracker-runtime.yml")]
actual = [(name, value) for name, _, value in matches]
if actual != expected:
    raise SystemExit(f"unexpected runtime workflow callers: {matches}")
PY
}
validate_callers "$repo_root/.github/workflows" || fail "reusable runtime workflow has an alternate caller"
mutation_root="$tmp_dir/caller-mutation"
mkdir -p "$mutation_root"
cp "$repo_root/.github/workflows/"*.yml "$mutation_root/"
sed 's#uses: ./\.github/workflows/build-firecracker-runtime.yml#uses: yeetrun/yeet-vm-images/.github/workflows/build-firecracker-runtime.yml@main#' "$sync" >"$mutation_root/sync-latest-stable-firecracker.yml"
if validate_callers "$mutation_root" >/dev/null 2>&1; then fail "external/ref reusable-workflow caller mutation was accepted"; fi
cp "$sync" "$mutation_root/sync-latest-stable-firecracker.yml"
cat >"$mutation_root/alternate-caller.yaml" <<'YAML'
jobs:
  publish:
    uses: ./.github/workflows/build-firecracker-runtime.yml
YAML
if validate_callers "$mutation_root" >/dev/null 2>&1; then fail "second .yaml reusable-workflow caller mutation was accepted"; fi
publishers="$(rg -l --fixed-strings 'scripts/publish-firecracker-runtime-assets.sh' "$repo_root/.github/workflows" || true)"
[ "$publishers" = "$build" ] || fail "runtime publisher has an alternate workflow call path"

# A tag-only or preserved-draft v1 consumes that revision while no published
# release exists, so discovery must request v2 rather than replay v1.
all_tags="$tmp_dir/all-tags.txt"
published_tags_fixture="$tmp_dir/published-tags.txt"
printf '%s\n' firecracker-v1.16.1-yeet-v1 >"$all_tags"
: >"$published_tags_fixture"
allocation_fixture="$("$revision_resolver" v1.16.1 "$all_tags")"
published_fixture="$("$revision_resolver" v1.16.1 "$published_tags_fixture")"
jq -e '.next_release == "firecracker-v1.16.1-yeet-v2"' <<<"$allocation_fixture" >/dev/null || fail "tag-only/draft v1 did not allocate v2"
jq -e '.current_release == ""' <<<"$published_fixture" >/dev/null || fail "tag-only/draft v1 was treated as a published no-op"

# Every external action is full-SHA pinned; the local workflow call is the sole exception.
python3 - "$build" "$sync" "$checkout_sha" <<'PY'
from pathlib import Path
import re
import sys

checkout_sha = sys.argv[3]
checkout_count = 0
for raw_path in sys.argv[1:3]:
    path = Path(raw_path)
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = re.match(r"\s*-?\s*uses:\s*(\S+)\s*$", line)
        if not match:
            continue
        value = match.group(1)
        if value == "./.github/workflows/build-firecracker-runtime.yml":
            continue
        action = re.fullmatch(r"([^@]+)@([0-9a-f]{40})", value)
        if not action:
            raise SystemExit(f"{path}:{number}: action is not pinned to a full commit SHA: {value}")
        if action.group(1) == "actions/checkout":
            checkout_count += 1
            if action.group(2) != checkout_sha:
                raise SystemExit(f"{path}:{number}: unexpected actions/checkout pin")
if checkout_count != 2:
    raise SystemExit(f"expected two pinned actions/checkout uses, found {checkout_count}")
PY

# No mutable alias, overwrite, destructive cleanup, or catalog mutation path.
for workflow in "$build" "$sync"; do
	for forbidden in '--clobber' '--overwrite' 'runtime-catalog.json' 'make_latest' 'gh release delete' 'git tag -f'; do
		reject_text "$workflow" "$forbidden" "forbidden mutable publication behavior remains: $forbidden"
	done
done

# Operator prerequisites and repository-admin boundary must be explicit.
for required in \
	'firecracker-runtime-publish' \
	'firecracker-runtime-overrides' \
	'YEET_RUNTIME_GITHUB_APP_CLIENT_ID' \
	'YEET_RUNTIME_GITHUB_APP_PRIVATE_KEY' \
	'Administration: read' \
	'Contents: write' \
	'repository immutable releases' \
	'credentials and scheduled publication remain disabled' \
	'Task 5' \
	'repository administrators' \
	'fails before creating a runtime tag or release' \
	'does not edit `runtime-catalog.json`'; do
	require_text "$readme" "$required" "README prerequisite or boundary is missing: $required"
done

for summary_text in \
	'Discovery failed. Inspect the failed step before retrying.' \
	'Candidate publication failed. Inspect the failed step; do not reuse a consumed runtime ID.' \
	'Candidate outputs are missing. Inspect the publication job and preserved release state.'; do
	if ! grep -Fq "$summary_text" "$build" "$sync"; then fail "actionable workflow failure summary is missing: $summary_text"; fi
done

[ "$(git -C "$repo_root" status --porcelain=v1)" = "$initial_status" ] || fail "test changed repository status"
echo "Firecracker runtime workflow structure verified"
