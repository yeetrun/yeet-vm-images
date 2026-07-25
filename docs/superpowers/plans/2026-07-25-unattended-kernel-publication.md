# Unattended Kernel Publication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make stable kernel publication catalog-first, unattended, retryable, and compatible with already released Catch versions.

**Architecture:** Split trusted-catalog state from public-package state in the scheduler. Promote and publicly verify the immutable catalog identity before the reusable package workflow can expose its schema-2 selector, using scoped job permissions and no pull request.

**Tech Stack:** GitHub Actions, Bash, `curl`, `jq`, GitHub raw content, existing immutable kernel releases and package workflows.

## Global Constraints

- A new Linux kernel version must not require the latest Yeet or Catch.
- Do not relax trusted catalog verification for component-managed VMs.
- No human approval, pull request, or repository-wide permission change belongs in the scheduled path.
- Package publication must be recoverable independently from catalog promotion.
- Production changes follow test-first red-green-refactor cycles.

---

## File Structure

- Create `scripts/wait-for-public-kernel-catalog.sh`
  - Wait out the public raw-content cache lifetime, then require the exact
    release ID and manifest digest in both the catalog entries and stable
    channel.
- Create `scripts/test-wait-for-public-kernel-catalog.sh`
  - Exercise successful verification, catalog mismatch, and test-controlled
    zero-delay behavior.
- Modify `scripts/test-kernel-release-workflows.sh`
  - Enforce distinct promotion/package state, catalog-first dependencies,
    concurrency, scoped permissions, and the absence of PR automation.
- Modify `.github/workflows/sync-latest-stable-kernel.yml`
  - Detect independent repair state, directly promote the catalog, verify its
    public URL, and publish packages only afterward.
- Modify `docs/component-release-runbook.md`
  - State the automated catalog-before-package invariant and recovery behavior.

### Task 1: Workflow Contract Tests

**Files:**
- Modify: `scripts/test-kernel-release-workflows.sh`
- Test: `scripts/test-kernel-release-workflows.sh`

**Interfaces:**
- Consumes: existing `job_block` and assertion helpers.
- Produces: executable assertions for the scheduler's dependency and permission
  contract.

- [ ] **Step 1: Write failing assertions**

Require:

```bash
assert_contains "$sync_workflow" "package_publication_needed:"
assert_contains "$sync_workflow" "group: sync-latest-stable-kernel"
assert_not_contains "$sync_workflow" "pull-requests: write"
assert_not_contains "$sync_workflow" "peter-evans/create-pull-request@"
assert_job_contains "$sync_workflow" "promote-kernel-catalog" "contents: write"
assert_job_contains "$sync_workflow" "promote-kernel-catalog" "git push --force-with-lease="
assert_job_contains "$sync_workflow" "promote-kernel-catalog" "scripts/wait-for-public-kernel-catalog.sh"
assert_job_contains "$sync_workflow" "publish-kernel-packages" "- promote-kernel-catalog"
assert_job_contains "$sync_workflow" "publish-kernel-packages" "needs.promote-kernel-catalog.result == 'success'"
assert_job_contains "$sync_workflow" "publish-kernel-packages" "pages: write"
assert_job_not_contains "$sync_workflow" "publish-kernel-packages" "pull-requests:"
```

Replace the old assertions that require PR creation and package-before-promotion.

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/test-kernel-release-workflows.sh
```

Expected: FAIL because `package_publication_needed` and catalog-first
dependencies do not exist and PR automation is still present.

- [ ] **Step 3: Leave the test red for Tasks 2 and 3**

Do not weaken the assertions. The production workflow change in Task 3 makes
them pass.

### Task 2: Public Catalog Visibility Gate

**Files:**
- Create: `scripts/test-wait-for-public-kernel-catalog.sh`
- Create: `scripts/wait-for-public-kernel-catalog.sh`

**Interfaces:**
- Consumes: `<catalog-url> <release-id> <manifest-sha256>`.
- Produces: exit 0 only after the public catalog selects the exact trusted
  identity; otherwise a non-zero exit.
- Environment:
  `YEET_KERNEL_CATALOG_SETTLE_SECONDS` defaults to `305`,
  `YEET_KERNEL_CATALOG_ATTEMPTS` defaults to `12`, and
  `YEET_KERNEL_CATALOG_RETRY_SECONDS` defaults to `10`.

- [ ] **Step 1: Write the failing script test**

Create fixtures in a temporary directory with literal release and digest
values. Invoke the missing verifier with settle and retry delays set to zero.
Assert that a matching catalog succeeds and a mismatched stable channel fails:

```bash
YEET_KERNEL_CATALOG_SETTLE_SECONDS=0 \
YEET_KERNEL_CATALOG_ATTEMPTS=1 \
YEET_KERNEL_CATALOG_RETRY_SECONDS=0 \
  "$verifier" "file://$matching_catalog" "$release_id" "$manifest_sha256"

if YEET_KERNEL_CATALOG_SETTLE_SECONDS=0 \
  YEET_KERNEL_CATALOG_ATTEMPTS=1 \
  YEET_KERNEL_CATALOG_RETRY_SECONDS=0 \
  "$verifier" "file://$mismatched_catalog" "$release_id" "$manifest_sha256"; then
  echo "public catalog verifier accepted a mismatched stable channel" >&2
  exit 1
fi
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/test-wait-for-public-kernel-catalog.sh
```

Expected: FAIL because `scripts/wait-for-public-kernel-catalog.sh` is absent.

- [ ] **Step 3: Implement the verifier**

Validate the release ID, 64-character lowercase manifest digest, and numeric
environment controls. Sleep for the settle interval, then fetch the exact URL
without a cache-busting query and require:

```jq
any(.kernels[]; .kernel_id == $release and .manifest_sha256 == $manifest) and
.channels.amd64.stable == {kernel_id: $release, manifest_sha256: $manifest}
```

Retry only failed fetches or mismatched content. Emit the last failure after the
configured attempt count.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/test-wait-for-public-kernel-catalog.sh
```

Expected: PASS.

### Task 3: Catalog-First Scheduler

**Files:**
- Modify: `.github/workflows/sync-latest-stable-kernel.yml`
- Test: `scripts/test-kernel-release-workflows.sh`

**Interfaces:**
- Consumes: immutable kernel release metadata and public Pages package catalog.
- Produces: direct trusted catalog commit before any public selector package.

- [ ] **Step 1: Split scheduler state**

Add `package_publication_needed` to the detect job outputs. Default both
promotion and package publication to true. When reusing an immutable release,
set promotion false only if the repository kernel catalog selects its exact
release and manifest; set package publication false only if both the repository
package catalog and the public Pages package catalog select the same identity
with selector schema 2.

- [ ] **Step 2: Replace PR promotion with a direct race-checked commit**

Run promotion when either repair flag is true. Download the immutable release,
update and verify `kernel-catalog.json`, and commit only that path. Before
pushing, require the checked-out base to equal the refreshed `origin/main`; push
with:

```bash
git push --force-with-lease=refs/heads/main:"$remote_base" origin HEAD:main
```

Then call:

```bash
scripts/wait-for-public-kernel-catalog.sh \
  "https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/main/kernel-catalog.json" \
  "$KERNEL_RELEASE" \
  "$manifest_sha256"
```

- [ ] **Step 3: Put package publication after promotion**

Make `publish-kernel-packages` depend on `detect`, `build-kernel`, and
`promote-kernel-catalog`. Run it only when package publication is needed, the
kernel build succeeded or skipped, and catalog promotion/verification
succeeded.

- [ ] **Step 4: Scope permissions and concurrency**

Set the workflow default to `contents: read`, add a non-canceling
`sync-latest-stable-kernel` concurrency group, and grant write permissions only
on the build, promotion, and package jobs described in the design.

- [ ] **Step 5: Verify green**

Run:

```bash
bash scripts/test-kernel-release-workflows.sh
bash scripts/test-wait-for-public-kernel-catalog.sh
bash scripts/test-kernel-component-release.sh
bash scripts/test-kernel-packages.sh
```

Expected: PASS.

### Task 4: Operator Contract

**Files:**
- Modify: `docs/component-release-runbook.md`

**Interfaces:**
- Consumes: the implemented workflow behavior.
- Produces: concise recovery guidance without adding a human step to normal
  publication.

- [ ] **Step 1: Update the runbook**

Document the catalog-first invariant, direct scheduled promotion, public raw URL
settle/verification, independent retry state, and the fact that new kernel
versions keep selector schema 2.

- [ ] **Step 2: Check terminology**

Run:

```bash
rg -n "pull request|package.*before.*catalog|catalog.*before.*package|schema 2" \
  docs/component-release-runbook.md \
  docs/superpowers/specs/2026-07-25-unattended-kernel-publication-design.md
```

Expected: the normal kernel path is described as unattended and catalog-first.

### Task 5: Cross-Version Catch Verification

**Files:**
- Verify only: `/Users/shayne/code/yeet` tags `v0.10.6` and `v0.10.7`

**Interfaces:**
- Consumes: existing `pkg/catch/vm_kernel_component_sync_test.go`.
- Produces: evidence that schema-2 catalog-backed reboot sync does not depend on
  a new Catch patch.

- [ ] **Step 1: Compare the production code**

Run:

```bash
git -C /Users/shayne/code/yeet diff --no-index \
  <(git -C /Users/shayne/code/yeet show v0.10.6:pkg/catch/vm_kernel_sync.go) \
  <(git -C /Users/shayne/code/yeet show v0.10.7:pkg/catch/vm_kernel_sync.go)
```

Expected: no difference.

- [ ] **Step 2: Test both immutable source trees**

Export each tag to a temporary directory and run:

```bash
mise exec -- go test ./pkg/catch \
  -run 'TestAutoSyncVMGuestKernelComponentLock|TestAutoSyncVMGuestKernelRejectsCatalogManifestMismatch' \
  -count=1
```

Expected: PASS for v0.10.6 and v0.10.7.

- [ ] **Step 3: Keep Yeet unchanged**

Do not add a Catch version check or source patch. The scheduler ordering is the
compatibility fix.

### Task 6: Repository Verification

**Files:**
- Verify all modified files.

**Interfaces:**
- Produces: a clean local implementation ready to land.

- [ ] **Step 1: Run all shell tests**

Run:

```bash
for test_script in scripts/test-*.sh; do
  bash "$test_script"
done
```

Expected: PASS.

- [ ] **Step 2: Run the repository gate**

Run:

```bash
mise exec -- pre-commit run --all-files
```

Expected: PASS.

- [ ] **Step 3: Inspect the final diff**

Run:

```bash
git diff --check
git status --short
```

Expected: only the workflow, tests, verifier, runbook, design, and plan for this
fix are changed.
