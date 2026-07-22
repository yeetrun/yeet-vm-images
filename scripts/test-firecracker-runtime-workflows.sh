#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions and README literals must remain unexpanded.
set -euo pipefail
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$repo_root/.github/workflows/build-firecracker-runtime.yml"
integration="$repo_root/.github/workflows/test-firecracker-runtime-kvm.yml"
promotion="$repo_root/.github/workflows/promote-firecracker-runtime.yml"
integration_gate="$repo_root/runtime-integration.json"
readme="$repo_root/README.md"
published_kernel_downloader="$repo_root/scripts/download-published-kernel-release.sh"
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
require_file "$integration"
require_file "$promotion"
require_file "$integration_gate"
require_file "$readme"
require_file "$published_kernel_downloader"
require_file "$published_verifier"
require_file "$published_test"

# Scheduled/manual discovery and protected publication live in one workflow so
# environment secrets are resolved by the write-bearing job itself.
require_text "$build" '    - cron: "37 9 * * *"' "daily discovery schedule is missing or changed"
require_text "$build" '  workflow_dispatch:' "manual discovery trigger is missing"
[ "$(grep -Fc '    - cron:' "$build")" = 1 ] || fail "discovery workflow must contain exactly one schedule"
for input in allow_unsigned_tag allow_signer_rotation; do
	require_text "$build" "      $input:" "workflow_dispatch input is missing: $input"
done
for extra_trigger in '  push:' '  pull_request:' '  repository_dispatch:' '  workflow_call:'; do
	reject_text "$build" "$extra_trigger" "discovery workflow contains an unplanned trigger: $extra_trigger"
done

# The default token stays read-only. Writes use one protected serialized job.
require_text "$build" $'permissions:\n  contents: read' "workflow default token is not contents:read"
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
[ "$(grep -Fc 'GH_TOKEN: ${{ github.token }}' "$build")" = 1 ] || fail "default token must be limited to the read-only discovery step"
reject_text "$build" 'GH_TOKEN: ${{ secrets.' "personal or generic secret token fallback remains"

# Workflow identity must match Task 3 exactly.
require_text "$build" 'YEET_RUNTIME_WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}' "workflow repository context is missing"
require_text "$build" 'YEET_RUNTIME_WORKFLOW_FILE_PATH: ${{ job.workflow_file_path }}' "workflow file-path context is missing"
require_text "$build" 'YEET_RUNTIME_WORKFLOW_REF: ${{ job.workflow_ref }}' "workflow ref context is missing"
require_text "$build" 'YEET_RUNTIME_WORKFLOW_SHA: ${{ job.workflow_sha }}' "workflow SHA context is missing"

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

# Discovery, revision allocation, protected publication, and no-op reporting are
# bound to the same reviewed main-branch workflow.
require_text "$build" '  group: sync-latest-stable-firecracker' "discovery concurrency group is missing"
require_text "$build" '  cancel-in-progress: false' "discovery cancellation policy is missing"
require_text "$build" 'scripts/resolve-latest-firecracker.sh' "official stable release discovery is missing"
require_text "$build" 'scripts/verify-published-firecracker-runtime.sh' "published candidate is not verified before no-op"
require_text "$build" 'allocation="$(scripts/resolve-firecracker-runtime-release.sh "$upstream_version")"' "next revision is not allocated from all remote tag refs"
require_text "$build" 'published="$(scripts/resolve-firecracker-runtime-release.sh "$upstream_version" "$published_tags")"' "published candidates are not resolved separately"
require_text "$build" "jq -er '.upstream_version'" "discovery does not read the resolver's upstream_version field"
reject_text "$build" "jq -er '.version'" "discovery reads a nonexistent resolver version field"
require_text "$build" "runtime_id=\$runtime_id" "discovery does not expose the computed next runtime ID"
require_text "$build" 'REQUESTED_RUNTIME_ID: ${{ needs.discover.outputs.runtime_id }}' "replay-safe runtime ID is not passed to the serialized publishing job"
require_text "$build" 'Candidate already exists; no publication requested.' "verified no-op summary is missing"
require_text "$build" 'DISCOVERY_RESULT: ${{ needs.discover.result }}' "summary does not distinguish discovery failure from a verified no-op"

# Integration is started by the immutable runtime release event or an exact
# manual recovery request. Bootstrap dispatches discovery, never the build job.
require_text "$integration" '  release:' "integration release trigger is missing"
require_text "$integration" '    types: [published]' "integration trigger is not release:published"
require_text "$integration" '  workflow_dispatch:' "integration manual recovery trigger is missing"
for input in runtime_id manifest_sha256 ubuntu_guest_release nixos_guest_release current_kernel_release previous_kernel_release yeet_ref; do
	require_text "$integration" "      $input:" "integration workflow input is missing: $input"
done
require_text "$integration" 'startsWith(github.event.release.tag_name, '\''firecracker-v'\'')' "release path does not reject unrelated tags"
require_text "$integration" 'github.event.release.prerelease == false' "release path does not reject prereleases"
require_text "$integration" '!contains(github.event.release.tag_name, '\''-integration-'\'')' "integration evidence release recursion is not rejected"
require_text "$integration" '!contains(github.event.release.tag_name, '\''-canary-'\'')' "canary evidence release recursion is not rejected"
require_text "$integration" 'scripts/verify-published-firecracker-runtime.sh' "integration does not reverify the exact runtime release"
require_text "$integration" 'runs-on: [self-hosted, linux, x64, kvm, yeet-runtime-integration]' "integration runner labels differ"
require_text "$integration" 'sudo apt-get install -y curl gh git jq pipx python3' "integration runner dependencies are not installed by the pinned workflow"
require_text "$integration" 'pipx install check-jsonschema==0.37.4' "integration schema validator is not pinned by the workflow"
require_text "$integration" 'uses: actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16' "integration Go toolchain action is missing or not pinned"
require_text "$integration" 'go-version-file: yeet-src/go.mod' "integration Go version is not bound to the exact Yeet commit"
require_text "$integration" 'sudo install -d -o root -g root -m 0755 /var/lib/yeet-runtime-integration' "integration root is not created with trusted host ownership and mode"
require_text "$integration" '--work-dir "/var/lib/yeet-runtime-integration/run-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"' "integration VM state is not rooted below a trusted host directory"
require_text "$integration" '    environment: firecracker-runtime-integration-publish' "integration publishing environment is missing"
require_text "$integration" '      group: firecracker-runtime-integration-publish' "integration publishing concurrency is missing"
require_text "$integration" '      cancel-in-progress: false' "integration publication cancellation differs"
require_text "$integration" $'permissions:\n  contents: read' "integration default token is not contents:read"
require_text "$integration" "uses: actions/create-github-app-token@$app_token_sha" "integration App-token pin differs"
require_text "$integration" 'permission-contents: write' "integration token lacks Contents:write"
require_text "$integration" 'permission-administration: read' "integration token lacks immutable-release settings read access"
reject_text "$integration" 'permission-pull-requests:' "integration token has unnecessary pull-request permission"
[ "$(grep -Fc 'steps.integration-app-token.outputs.token' "$integration")" = 1 ] || fail "integration App token is exposed outside the publication step"
require_text "$integration" 'scripts/test-firecracker-runtime-kvm.sh' "integration KVM harness is missing"
require_text "$repo_root/scripts/test-firecracker-runtime-kvm.sh" 'scripts/download-published-guest-base.sh' "integration harness does not use the immutable published guest-base downloader"
require_text "$repo_root/scripts/test-firecracker-runtime-kvm.sh" 'scripts/download-published-kernel-release.sh' "integration harness does not use the immutable published-kernel downloader"
require_text "$repo_root/scripts/test-firecracker-runtime-kvm.sh" 'scripts/synthesize-firecracker-runtime-test-guest.sh' "integration harness does not build a hash-bound component test guest"
require_text "$integration" 'scripts/write-firecracker-runtime-attestation.sh' "integration attestation writer is missing"
require_text "$integration" 'scripts/publish-firecracker-runtime-attestation.sh' "integration attestation publisher is missing"
require_text "$integration" 'YEET_INTEGRATION_WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}' "integration workflow repository identity is missing"
require_text "$integration" 'YEET_INTEGRATION_WORKFLOW_FILE_PATH: ${{ job.workflow_file_path }}' "integration workflow path identity is missing"
require_text "$integration" 'YEET_INTEGRATION_WORKFLOW_REF: ${{ job.workflow_ref }}' "integration workflow ref identity is missing"
require_text "$integration" 'YEET_INTEGRATION_WORKFLOW_SHA: ${{ job.workflow_sha }}' "integration workflow SHA identity is missing"
require_text "$integration" 'yeet-src/scripts/test-firecracker-runtime-integration.sh' "exact Yeet checkout integration driver is not required"
reject_text "$integration" '/usr/local' "integration workflow depends on unversioned runner state"
python3 - "$integration" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"(?m)^      - name: Publish immutable integration evidence\n(?P<body>.*?)(?=^      - name:|\Z)",
    text,
    re.DOTALL,
)
if not match:
    raise SystemExit("integration publication step is missing")
body = match.group("body")
required = {
    "YEET_COMMIT": "${{ needs.normalize.outputs.yeet_ref }}",
    "UBUNTU_GUEST_RELEASE": "${{ needs.normalize.outputs.ubuntu_guest_release }}",
    "NIXOS_GUEST_RELEASE": "${{ needs.normalize.outputs.nixos_guest_release }}",
    "CURRENT_KERNEL_RELEASE": "${{ needs.normalize.outputs.current_kernel_release }}",
    "PREVIOUS_KERNEL_RELEASE": "${{ needs.normalize.outputs.previous_kernel_release }}",
}
for name, value in required.items():
    if f"          {name}: {value}\n" not in body:
        raise SystemExit(f"integration publication step does not bind {name}")
PY

jq -e '
  keys == ["release_event", "schema_version"] and .schema_version == 1 and
  (.release_event | keys == ["current_kernel_release", "enabled", "nixos_guest_release", "previous_kernel_release", "ubuntu_guest_release", "yeet_ref"]) and
  .release_event.enabled == false and all(.release_event | del(.enabled)[]; . == null)
' "$integration_gate" >/dev/null || fail "runtime integration activation gate is not closed and dormant"
activation_filter='keys == ["release_event", "schema_version"] and .schema_version == 1 and
  (.release_event | keys == ["current_kernel_release", "enabled", "nixos_guest_release", "previous_kernel_release", "ubuntu_guest_release", "yeet_ref"]) and
  if .release_event.enabled == false then all(.release_event | del(.enabled)[]; . == null)
  else .release_event.enabled == true and
    (.release_event.ubuntu_guest_release | test("^guest-ubuntu-[0-9]+[.][0-9]+-amd64-v[1-9][0-9]*$")) and
    (.release_event.nixos_guest_release | test("^guest-nixos-[0-9]+[.][0-9]+-amd64-v[1-9][0-9]*$")) and
    (.release_event.current_kernel_release | test("^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$")) and
    (.release_event.previous_kernel_release | test("^kernel-linux-[0-9]+[.][0-9]+([.][0-9]+)*-yeet-v[1-9][0-9]*$")) and
    (.release_event.yeet_ref | test("^[0-9a-f]{40}$")) end'
jq '.release_event={enabled:true,ubuntu_guest_release:"guest-ubuntu-26.04-amd64-v2",nixos_guest_release:"guest-nixos-26.05-amd64-v2",current_kernel_release:"kernel-linux-7.1.4-yeet-v4",previous_kernel_release:"kernel-linux-7.1.4-yeet-v3",yeet_ref:"76543210fedcba9876543210fedcba9876543210"}' "$integration_gate" >"$tmp_dir/enabled-integration.json"
jq -e "$activation_filter" "$tmp_dir/enabled-integration.json" >/dev/null || fail "fully pinned activation gate was rejected"
for mutation in partial-disabled partial-enabled latest-enabled unknown-enabled; do
	case "$mutation" in
		partial-disabled) jq '.release_event.ubuntu_guest_release="ubuntu-26.04-amd64-v29"' "$integration_gate" >"$tmp_dir/$mutation.json" ;;
		partial-enabled) jq '.release_event.enabled=true' "$integration_gate" >"$tmp_dir/$mutation.json" ;;
		latest-enabled) jq '.release_event.ubuntu_guest_release="ubuntu-26.04-amd64-latest"' "$tmp_dir/enabled-integration.json" >"$tmp_dir/$mutation.json" ;;
		unknown-enabled) jq '.release_event.extra=true' "$tmp_dir/enabled-integration.json" >"$tmp_dir/$mutation.json" ;;
	esac
	if jq -e "$activation_filter" "$tmp_dir/$mutation.json" >/dev/null 2>&1; then fail "activation gate accepted mutation: $mutation"; fi
done
require_text "$integration" 'if .release_event.enabled == false' "integration workflow does not validate the dormant gate branch"
require_text "$integration" 'then all(.release_event | del(.enabled)[]; . == null)' "disabled activation gate could expose partial values"
require_text "$integration" 'else .release_event.enabled == true' "enabled activation gate is not explicit"

# Candidate promotion is a reviewed pull request from a fresh main checkout.
require_text "$promotion" '  workflow_dispatch:' "promotion manual trigger is missing"
for input in runtime_id manifest_sha256 integration_attestation_url integration_attestation_sha256; do
	require_text "$promotion" "      $input:" "promotion workflow input is missing: $input"
done
require_text "$promotion" '    environment: firecracker-runtime-promotion' "promotion environment is missing"
require_text "$promotion" 'group: firecracker-runtime-promotion-${{ inputs.runtime_id }}-candidate' "per-runtime promotion concurrency is missing"
require_text "$promotion" 'cancel-in-progress: false' "promotion cancellation policy differs"
require_text "$promotion" $'permissions:\n  contents: read' "promotion default token is not contents:read"
require_text "$promotion" "uses: actions/create-github-app-token@$app_token_sha" "promotion App-token pin differs"
require_text "$promotion" 'permission-contents: write' "promotion token lacks Contents:write"
require_text "$promotion" 'permission-pull-requests: write' "promotion token lacks Pull requests:write"
[ "$(grep -Fc 'steps.promotion-app-token.outputs.token' "$promotion")" = 1 ] || fail "promotion App token is exposed outside the push/PR step"
require_text "$promotion" 'git fetch --no-tags origin main' "promotion does not refresh origin/main"
reject_text "$promotion" 'git checkout --detach origin/main' "promotion silently executes scripts from a newly advanced main"
require_text "$promotion" '          ref: ${{ job.workflow_sha }}' "promotion checkout is not pinned to the loaded workflow SHA"
require_text "$promotion" 'YEET_PROMOTION_WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}' "promotion workflow repository identity is missing"
require_text "$promotion" 'YEET_PROMOTION_WORKFLOW_FILE_PATH: ${{ job.workflow_file_path }}' "promotion workflow path identity is missing"
require_text "$promotion" 'YEET_PROMOTION_WORKFLOW_REF: ${{ job.workflow_ref }}' "promotion workflow ref identity is missing"
require_text "$promotion" 'YEET_PROMOTION_WORKFLOW_SHA: ${{ job.workflow_sha }}' "promotion workflow SHA identity is missing"
require_text "$promotion" '[ "${GITHUB_JOB:-}" = promote-candidate ]' "promotion job ID is not checked"
require_text "$promotion" 'repository=yeetrun/yeet-vm-images' "promotion repository identity is not checked"
require_text "$promotion" 'workflow_ref="$repository/.github/workflows/promote-firecracker-runtime.yml@refs/heads/main"' "promotion main-only workflow ref is not checked"
require_text "$promotion" '[ "$(git rev-parse HEAD)" = "$YEET_PROMOTION_WORKFLOW_SHA" ]' "promotion checkout is not bound to workflow SHA"
require_text "$promotion" '[ "$(git rev-parse origin/main)" = "$YEET_PROMOTION_WORKFLOW_SHA" ]' "promotion does not fail when main advances beyond workflow SHA"
require_text "$promotion" 'branch="promote/$RUNTIME_ID/candidate"' "promotion branch name differs"
require_text "$promotion" 'git push origin "HEAD:refs/heads/$branch"' "promotion does not use a non-force push"
reject_text "$promotion" '--force' "promotion contains a force push"
reject_text "$promotion" 'gh pr merge' "promotion auto-merges"
require_text "$promotion" 'git diff --name-only HEAD^ HEAD' "promotion does not verify the exact committed path"
require_text "$promotion" 'runtime-catalog.json' "promotion does not commit the runtime catalog"
require_text "$promotion" 'scripts/promote-firecracker-runtime.sh' "promotion script is not used"

validate_promotion_identity() {
	python3 - "$1" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "          ref: ${{ job.workflow_sha }}\n",
    "          YEET_PROMOTION_WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}\n",
    "          YEET_PROMOTION_WORKFLOW_FILE_PATH: ${{ job.workflow_file_path }}\n",
    "          YEET_PROMOTION_WORKFLOW_REF: ${{ job.workflow_ref }}\n",
    "          YEET_PROMOTION_WORKFLOW_SHA: ${{ job.workflow_sha }}\n",
    '          [ "${GITHUB_JOB:-}" = promote-candidate ]\n',
    "          repository=yeetrun/yeet-vm-images\n",
    '          workflow_ref="$repository/.github/workflows/promote-firecracker-runtime.yml@refs/heads/main"\n',
    '          [ "${GITHUB_WORKFLOW_REF:-}" = "$workflow_ref" ]\n',
    '          [ "$YEET_PROMOTION_WORKFLOW_REPOSITORY" = "$repository" ]\n',
    '          [ "$YEET_PROMOTION_WORKFLOW_FILE_PATH" = .github/workflows/promote-firecracker-runtime.yml ]\n',
    '          [ "$YEET_PROMOTION_WORKFLOW_REF" = "$workflow_ref" ]\n',
    '          [ "$(git rev-parse HEAD)" = "$YEET_PROMOTION_WORKFLOW_SHA" ]\n',
    '          [ "$(git rev-parse origin/main)" = "$YEET_PROMOTION_WORKFLOW_SHA" ] || {\n',
]
for value in required:
    if text.count(value) != 1:
        raise SystemExit(f"promotion identity contract missing or duplicated: {value.strip()}")
identity = text.find("      - name: Verify reviewed promotion workflow identity")
token = text.find("      - name: Mint repository-scoped promotion token")
if identity < 0 or token < 0 or identity >= token:
    raise SystemExit("promotion identity check must complete before App-token minting")
if "git checkout --detach origin/main" in text:
    raise SystemExit("promotion must not execute scripts from a different origin/main commit")
PY
}
validate_promotion_identity "$promotion" || fail "promotion identity contract is invalid"
promotion_mutations="$tmp_dir/promotion-identity-mutations"
mkdir -p "$promotion_mutations"
cp "$promotion" "$promotion_mutations/ref.yml"
sed -i.bak 's#@refs/heads/main#@refs/heads/review#' "$promotion_mutations/ref.yml" && rm "$promotion_mutations/ref.yml.bak"
cp "$promotion" "$promotion_mutations/repository.yml"
sed -i.bak 's#repository=yeetrun/yeet-vm-images#repository=other/repository#' "$promotion_mutations/repository.yml" && rm "$promotion_mutations/repository.yml.bak"
cp "$promotion" "$promotion_mutations/path.yml"
sed -i.bak 's#YEET_PROMOTION_WORKFLOW_FILE_PATH" = .github/workflows/promote-firecracker-runtime.yml#YEET_PROMOTION_WORKFLOW_FILE_PATH" = .github/workflows/other.yml#' "$promotion_mutations/path.yml" && rm "$promotion_mutations/path.yml.bak"
cp "$promotion" "$promotion_mutations/job.yml"
sed -i.bak 's#GITHUB_JOB:-}" = promote-candidate#GITHUB_JOB:-}" = other-job#' "$promotion_mutations/job.yml" && rm "$promotion_mutations/job.yml.bak"
cp "$promotion" "$promotion_mutations/job-context.yml"
sed -i.bak 's#YEET_PROMOTION_WORKFLOW_REPOSITORY: \${{ job.workflow_repository }}#YEET_PROMOTION_WORKFLOW_REPOSITORY: ${{ github.repository }}#' "$promotion_mutations/job-context.yml" && rm "$promotion_mutations/job-context.yml.bak"
cp "$promotion" "$promotion_mutations/file-context.yml"
sed -i.bak 's#YEET_PROMOTION_WORKFLOW_FILE_PATH: \${{ job.workflow_file_path }}#YEET_PROMOTION_WORKFLOW_FILE_PATH: ${{ github.workflow }}#' "$promotion_mutations/file-context.yml" && rm "$promotion_mutations/file-context.yml.bak"
cp "$promotion" "$promotion_mutations/ref-context.yml"
sed -i.bak 's#YEET_PROMOTION_WORKFLOW_REF: \${{ job.workflow_ref }}#YEET_PROMOTION_WORKFLOW_REF: ${{ github.workflow_ref }}#' "$promotion_mutations/ref-context.yml" && rm "$promotion_mutations/ref-context.yml.bak"
cp "$promotion" "$promotion_mutations/sha-context.yml"
sed -i.bak 's#YEET_PROMOTION_WORKFLOW_SHA: \${{ job.workflow_sha }}#YEET_PROMOTION_WORKFLOW_SHA: ${{ github.sha }}#' "$promotion_mutations/sha-context.yml" && rm "$promotion_mutations/sha-context.yml.bak"
cp "$promotion" "$promotion_mutations/checkout.yml"
sed -i.bak 's#ref: \${{ job.workflow_sha }}#ref: main#' "$promotion_mutations/checkout.yml" && rm "$promotion_mutations/checkout.yml.bak"
for mutation in "$promotion_mutations"/*.yml; do
	if validate_promotion_identity "$mutation" >/dev/null 2>&1; then fail "promotion identity mutation was accepted: $(basename "$mutation")"; fi
done

# The manual bootstrap is the direct build/publish workflow. No integration or
# promotion workflow may invoke it as a nested write path.
reject_text "$integration" 'build-firecracker-runtime.yml' "integration calls the build workflow directly"
reject_text "$promotion" 'build-firecracker-runtime.yml' "promotion calls the build workflow directly"
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

# Every external action is full-SHA pinned.
python3 - "$build" "$integration" "$promotion" "$checkout_sha" <<'PY'
from pathlib import Path
import re
import sys

checkout_sha = sys.argv[4]
checkout_count = 0
for raw_path in sys.argv[1:4]:
    path = Path(raw_path)
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = re.match(r"\s*-?\s*uses:\s*(\S+)\s*$", line)
        if not match:
            continue
        value = match.group(1)
        action = re.fullmatch(r"([^@]+)@([0-9a-f]{40})", value)
        if not action:
            raise SystemExit(f"{path}:{number}: action is not pinned to a full commit SHA: {value}")
        if action.group(1) == "actions/checkout":
            checkout_count += 1
            if action.group(2) != checkout_sha:
                raise SystemExit(f"{path}:{number}: unexpected actions/checkout pin")
if checkout_count != 7:
    raise SystemExit(f"expected exactly seven pinned actions/checkout uses, found {checkout_count}")
PY

# No mutable alias, overwrite, destructive cleanup, or catalog mutation path.
for workflow in "$build"; do
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
	if ! grep -Fq "$summary_text" "$build"; then fail "actionable workflow failure summary is missing: $summary_text"; fi
done

[ "$(git -C "$repo_root" status --porcelain=v1)" = "$initial_status" ] || fail "test changed repository status"
echo "Firecracker runtime workflow structure verified"
