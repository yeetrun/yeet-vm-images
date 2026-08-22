# Component Release Runbook

This runbook gates promotion of independently published VM guest bases and
host runtimes. A workflow completing successfully creates a candidate; it does
not by itself make that candidate stable. Stable guest kernel package releases
use the separate unattended path described below.

## Compatibility invariant

Existing monolithic bundles, catalog entries, tags, and release assets remain
immutable and available. A Catch upgrade may measure an existing VM into an
independent guest/kernel/runtime composition, but it must preserve that VM's
stored image version and paths, must not replace its disk, and must not restart
it. If exact evidence is missing or contradictory, the VM remains on its old
launch paths with `adoption-blocked` status.

The guest-agent/vsock boundary is untrusted for host component selection. A
guest kernel selector is a request that Catch resolves against verified host
catalog metadata. No guest request may select, download, stage, or promote a
host Firecracker runtime.

## Stable kernel package automation

The scheduled stable-kernel workflow is catalog-first and requires no human
promotion step. It publishes or reuses an immutable kernel release, commits the
exact release ID and manifest SHA-256 to `kernel-catalog.json`, waits for the
ordinary public raw catalog URL used by released Catch versions to show the new
identity, waits one additional full cache lifetime, and verifies the identity
again before publishing apt or Nix selector metadata.

Catalog promotion and public package state are detected independently. A later
scheduled run repairs either half if a prior run stopped after the catalog
commit or after package deployment. The workflow writes `main` with
workflow-scoped `contents: write`, while package publication separately receives
Pages and OIDC write permissions. It does not create or merge a pull request.

Kernel versions may change release IDs, manifest digests, and checksums, but
guest packages continue to emit selector schema 2. Catch versions that already
support that catalog-backed schema do not need an update for each new kernel.

## Promotion order

1. Ship Catch dual-read support, independent immutable caches, measured legacy
   adoption, component provisioning, and runtime status and rollback support.
2. Install that exact Catch revision on a canary host. Confirm representative
   v11, v15, and v29 monolithic VMs retain their image provenance, disk, running
   PID, and exact matching Firecracker+jailer pair during adoption.
3. Publish immutable guest-base candidates and, when testing kernel behavior,
   use an immutable kernel release. Record exact release IDs and manifest
   SHA-256 values; do not move reviewed guest-base or runtime stable pointers.
4. Provision both Ubuntu and NixOS candidates through an exact promoted host
   runtime. Confirm the Firecracker child runs as the host `yeet-vm` user through
   the runtime's matching jailer.
5. Install or select a verified newer kernel inside each guest, run
   `yeet vm kernel sync <vm>`, and reboot deliberately. Confirm only the kernel
   identity changes unless a host runtime was separately staged.
6. Exercise raw and ZFS-backed disks, default and custom data/service roots,
   readiness, disk-only snapshot/restore/clone where supported, runtime trial
   rollback, and prune dry-runs. Confirm `yeet vm images update` does not change
   a running VM's PID, unit, disk, or component lock.
7. Store validation evidence under
   `attestations/components/<component-id>/<manifest-sha256>/validation.json`.
   Open a reviewed PR that changes only the intended guest-base or runtime
   candidate/stable catalog pointers, then merge it after all required checks
   pass. Stable kernel package promotion remains the unattended catalog-first
   workflow above.
8. Retain legacy catalog entries, tags, and assets indefinitely until a separate
   deprecation policy is explicitly approved.

## Required evidence

Record the Catch and Yeet commits, host architecture, component release IDs and
manifest digests, old and new VM status, Firecracker and jailer versions and
hashes, child process UID, booted kernel, disk backend, roots exercised, and the
commands and results for reboot, readiness, rollback, restore/clone, image
update, and prune. Do not include private hostnames, usernames, addresses, or
filesystem layout in committed public evidence; use neutral capability labels.

For a boot-performance promotion, also record the host VM-unit start to the
first successful public-key SSH command as the primary metric. Discard one
warm-up, retain at least 20 raw warm-boot samples, and report minimum, p50, p95,
maximum, and failed-boot count. Record the matching Firecracker start, first
kernel message, init entry, guest-ready observation, and multi-user boundaries
when present so host observation latency is not confused with guest startup.
Include raw and ZFS-backed Ubuntu results, the NixOS result, package or rebuild
compatibility, the booted kernel identity, and the exact guest, kernel, runtime,
Catch, and Yeet source identities used for every result.

A boot-performance candidate cannot move stable with incomplete phase evidence,
any failed warm boot, a Firecracker-to-kernel p95 regression above 10 percent,
or an unexplained SSH p50 regression. A performance-only change must improve
SSH p50 by at least 50 milliseconds. After promotion, resolve artifacts through
the ordinary public stable catalogs and pass at least five additional boots per
affected guest family before declaring the rollout complete.

Promotion is blocked if a release or manifest is mutable, an artifact digest is
wrong, a Firecracker+jailer version pair differs, a guest can influence host
runtime selection, adoption restarts a VM, rollback fails, or required evidence
is incomplete.
