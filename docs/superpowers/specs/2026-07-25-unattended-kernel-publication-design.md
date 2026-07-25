# Unattended Kernel Publication Design

## Context

The scheduled stable-kernel workflow published the `yeet-vm-kernel 7.1.5-1`
guest package before the corresponding immutable kernel release was present in
the trusted host catalog on `main`. The release itself was valid and published,
but the catalog promotion used a pull request. Repository Actions are not
allowed to create pull requests, so the promotion job failed after the package
had already become installable.

This produced two host outcomes from the same Catch revision:

- a legacy VM without component state accepted the guest selector's checksums
  and changed kernels;
- a component-managed VM required the selector's release ID and manifest digest
  to resolve through `kernel-catalog.json`, rejected the untrusted selection,
  and kept its prior Firecracker kernel.

The difference was persisted VM state, not a Catch version difference. Catch
v0.10.6 and v0.10.7 contain the same component-kernel synchronization code.

## Goals

- Publish new guest kernel selectors only after their immutable release is
  present in the trusted kernel catalog.
- Verify the catalog through the ordinary public raw URL used by already
  released Catch binaries before making the package visible.
- Run the entire scheduled path without a pull request or human merge.
- Give each job only the GitHub Actions permissions it needs.
- Recover automatically when catalog promotion or package publication succeeds
  independently and the other half must be retried.
- Keep selector schema 2 stable so new kernel versions remain usable by Catch
  point releases that already support the component catalog contract.

## Non-Goals

- Do not require a Yeet or Catch upgrade for each new Linux kernel version.
- Do not weaken component-managed VM catalog verification.
- Do not change the broad repository setting that controls whether Actions may
  create pull requests; the kernel workflow no longer needs that permission.
- Do not auto-upgrade Catch or mutate VM host state outside the existing guest
  reboot synchronization path.
- Do not redesign Firecracker runtime or guest-base promotion.

## Publication Invariant

For a release ID `R` and manifest digest `M`, the package that writes selector
`{schema_version: 2, release_id: R, manifest_sha256: M}` may become public only
after all of the following are true:

1. The immutable GitHub release for `R` exists and its manifest hashes the
   published kernel assets.
2. `kernel-catalog.json` on `main` contains exactly one entry for `(R, M)` and
   the amd64 stable channel selects `(R, M)`.
3. The ordinary public URL
   `https://raw.githubusercontent.com/yeetrun/yeet-vm-images/main/kernel-catalog.json`
   returns that entry after the raw-content cache lifetime has elapsed.
4. Only then may apt, Nix metadata, and GitHub Pages expose the selector.

Catalog-first failure is safe: guests cannot install the new selector yet.
Package-first failure is unsafe for component-managed VMs because the guest can
request a release the host does not trust. The workflow must therefore make the
unsafe order impossible.

## Workflow Design

`sync-latest-stable-kernel.yml` remains the scheduled orchestrator:

1. Detect the latest stable kernel and resolve its immutable release.
2. Independently determine whether trusted catalog promotion is needed and
   whether the public package is missing or stale.
3. Build the immutable kernel release when necessary.
4. Promote `kernel-catalog.json` directly to `main` with a race-checked,
   catalog-only commit.
5. Wait out the raw-content cache lifetime and verify `(R, M)` through the
   ordinary public catalog URL.
6. Publish the package only when its public catalog is missing or stale.

Promotion runs when either side needs repair. This means a run can repair the
current package-without-catalog incident without rebuilding or republishing the
package, and a later run can retry a failed package deployment after catalog
promotion already succeeded.

The workflow uses a non-canceling concurrency group so manual and scheduled
runs cannot publish the same kernel concurrently.

## Permissions

The workflow default is `contents: read`.

- Detection: inherited read-only access.
- Kernel release build: `contents: write`.
- Catalog promotion: `contents: write`.
- Package publication: `contents: write`, `pages: write`, and
  `id-token: write`.

No job receives `pull-requests: write`, and no job creates or merges a pull
request.

## Compatibility Contract

Kernel version changes alter release IDs, manifest digests, and artifact
checksums, but not the selector protocol. Package publication continues to emit
selector schema 2, which Catch v0.10.6 already understands for
component-managed VMs. The trusted catalog must remain the authority for that
path.

There is intentionally no Catch patch in this fix. Requiring a new Catch build
would mask the publication bug and break the point-release-lag requirement.
Existing Yeet tests remain the compatibility proof for schema-2 component
selection; this work verifies those tests against both v0.10.6 and current
`main`.

## Validation

- Workflow contract tests fail if package publication no longer depends on
  successful catalog promotion and public verification.
- Workflow contract tests fail if pull-request automation or
  `pull-requests: write` returns.
- A script test verifies public-catalog matching, mismatch failure, and the
  cache-settle delay override used by tests.
- Kernel package tests continue to require selector schema 2 with release ID and
  manifest digest.
- The full VM image repository test set and pre-commit hook pass.
- The Yeet component-kernel tests pass for v0.10.6 and current `main` without
  source changes.

## Rollout

Land the workflow and verified 7.1.5 catalog repair on
`yeet-vm-images/main`, then dispatch the stable kernel sync once. If the public
raw URL still serves its prior cached catalog, the run will wait and verify
7.1.5 before finishing; it will observe that the 7.1.5 package is already public
and will not rebuild it. A subsequent reboot of the affected VM will use the
existing Catch v0.10.6 synchronization path and select the trusted 7.1.5
kernel.
