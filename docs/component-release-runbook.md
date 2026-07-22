# Component Release Runbook

This runbook gates promotion of independently published VM guest bases and
kernels. A workflow completing successfully creates a candidate; it does not by
itself make that candidate stable.

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

## Promotion order

1. Ship Catch dual-read support, independent immutable caches, measured legacy
   adoption, component provisioning, and runtime status and rollback support.
2. Install that exact Catch revision on a canary host. Confirm representative
   v11, v15, and v29 monolithic VMs retain their image provenance, disk, running
   PID, and exact matching Firecracker+jailer pair during adoption.
3. Publish an immutable kernel candidate and guest-base candidates. Record exact
   release IDs and manifest SHA-256 values; do not move stable pointers.
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
   Open a reviewed PR that changes only the intended candidate/stable catalog
   pointers, then merge it after all required checks pass.
8. Retain legacy catalog entries, tags, and assets indefinitely until a separate
   deprecation policy is explicitly approved.

## Required evidence

Record the Catch and Yeet commits, host architecture, component release IDs and
manifest digests, old and new VM status, Firecracker and jailer versions and
hashes, child process UID, booted kernel, disk backend, roots exercised, and the
commands and results for reboot, readiness, rollback, restore/clone, image
update, and prune. Do not include private hostnames, usernames, addresses, or
filesystem layout in committed public evidence; use neutral capability labels.

Promotion is blocked if a release or manifest is mutable, an artifact digest is
wrong, a Firecracker+jailer version pair differs, a guest can influence host
runtime selection, adoption restarts a VM, rollback fails, or required evidence
is incomplete.
