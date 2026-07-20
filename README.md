# Yeet VM Images

This repository builds and publishes the official VM image bundles for Yeet.
The Yeet runtime is maintained in
[yeetrun/yeet](https://github.com/yeetrun/yeet), and the public site is
[yeetrun.com](https://yeetrun.com).

The runtime repository owns the CLI, catch, service lifecycle, and the guest
binaries `yeet-init` and `yeet-agent`. This repository owns the bootable VM
payloads that catch resolves, downloads, verifies, and starts with
Firecracker.

Official payload families:

- `vm://ubuntu/26.04`
- `vm://nixos/26.05`

Each published bundle includes:

- `manifest.json`
- `vmlinux`
- `rootfs.ext4.zst`
- `firecracker`
- `jailer`
- `kernel.config`
- `checksums.txt`

The stable latest manifest URLs are the catch-facing entry points:

- Ubuntu:
  `https://github.com/yeetrun/yeet-vm-images/releases/download/ubuntu-26.04-amd64-latest/manifest.json`
- NixOS:
  `https://github.com/yeetrun/yeet-vm-images/releases/download/nixos-26.05-amd64-latest/manifest.json`

`catalog.json` maps official `vm://...` payload families to latest manifest
URLs. Publishing a new image version updates the immutable release and the
matching `*-latest` release. The catalog only changes when a family is added,
renamed, or intentionally redirected.

## How Yeet Uses These Images

When a user asks Yeet for an official VM payload, catch resolves the payload
through `catalog.json`, reads the manifest, verifies checksums, downloads the
rootfs, kernel, and matching Firecracker and jailer binaries, then launches the
guest through the jailer with Firecracker direct kernel boot.

Inside the guest:

- `yeet-init` runs before systemd and handles yeet-specific readiness.
- `yeet-agent` exposes live guest network state over Firecracker vsock.
- `/etc/yeet-vm` carries yeet-owned metadata such as hostname, SSH keys,
  and network snippets.
- Ubuntu and NixOS keep their normal package manager and rebuild behavior.

The image build uses guest binaries from `yeetrun/yeet`; workflows pin that
source with `yeet_ref`.

## Image Policy

These images are tuned for fast microVM startup while keeping Ubuntu and NixOS
distribution behavior intact.

For performance and size:

- yeet kernels boot directly under Firecracker without an initrd;
- Ubuntu images remove distro kernel, module, bootloader, initramfs, snap, and
  unused server-image packages;
- boot-time services that do not help a yeet VM reach readiness are removed or
  masked;
- rootfs images are compressed as `rootfs.ext4.zst`.

For compatibility:

- Ubuntu package-owned paths stay intact, including `/usr/sbin`;
- Ubuntu package upgrades should not reinstall a distro kernel path that the VM
  will not boot;
- NixOS images ship a normal flake-first `/etc/nixos` that users can inspect
  and rebuild with `nixos-rebuild`;
- yeet-owned metadata stays data-only under `/etc/yeet-vm`.

For guest functionality:

- `yeet-agent` is enabled so catch can query current guest network state;
- `/dev/net/tun`, forwarding, nftables, iptables, and rsync support are present
  for common router, tunnel, and file-copy workflows.

## Terminal Terminfo

Some terminals publish TERM values that base distribution images may not know
yet. Ghostty uses `xterm-ghostty`; official images embed the matching terminfo
entry for convenience from `assets/xterm-ghostty.terminfo`.

## Yeet Kernel

The images boot a yeet-managed Linux kernel instead of the distribution kernel.
It is built for Firecracker direct kernel boot, so the VM does not need an
initrd. The config starts from Firecracker's microVM kernel baseline and adds
the features yeet images need for guest networking, router-style workloads,
file sync, and in-guest Nix builds.

Each upstream kernel version is published once as a canonical kernel release,
for example `kernel-linux-<version>-yeet-v<N>`. A canonical kernel release
contains:

- `vmlinux`
- `kernel.config`
- `kernel-manifest.json`
- `kernel-checksums.txt`

Image workflows consume those canonical assets. Image bundles still include
`vmlinux`, `kernel.config`, and checksums so each bundle remains
self-contained for catch.

The `Sync latest stable Linux kernel VM images` workflow runs daily and can be
manually dispatched. It checks kernel.org latest stable metadata, compares the
Ubuntu and NixOS latest manifests, resolves or publishes the needed canonical
kernel release, publishes package metadata from that same release, then builds
only stale image families.

Image versions use hybrid tags such as
`ubuntu-26.04-amd64-kernel-<kernel>-v<N>`. The kernel segment records the
kernel line; the final `v<N>` is the per-family image revision.

The package workflow publishes the same canonical kernel release through
distro-native package metadata:

- Ubuntu apt repository:
  `https://yeetrun.github.io/yeet-vm-images/apt`
- NixOS flake metadata under `kernel-packages/metadata.nix`

Ubuntu images include the yeet apt source and install `yeet-vm-kernel` by
default. NixOS images include and enable the yeet kernel package flake by
default. Image bundles, apt metadata, and Nix metadata all track the same
canonical kernel assets.

## Image Families

### Ubuntu 26.04

The Ubuntu image starts from the official Ubuntu 26.04 cloud image and applies
the yeet fast profile. It boots a yeet-managed Firecracker kernel, uses
`yeet-init` before systemd, enables `yeet-agent`, and omits `initrd.img`.

The fast profile keeps Ubuntu package behavior intact while removing packages
and services that do not contribute to yeet VM startup. It also installs the
yeet kernel apt source by default, keeps networking and firewall userspace
available, preserves common host-tool-compatible ext4 features, and masks snapd
because the fast image intentionally does not support snaps.

### NixOS 26.05

The NixOS image is built from a flake-pinned `nixpkgs` input using NixOS
modules. It boots the same yeet-managed Firecracker kernel and uses the same
`yeet-init` and `yeet-agent` guest integration as Ubuntu.

The shipped `/etc/nixos` remains a normal NixOS configuration:
`flake.nix`, `flake.lock`, `system.nix`, and `yeet/vm.nix` are present in the
guest, and users can rebuild with `nixos-rebuild switch --flake .#yeet-vm`.
The yeet module handles VM metadata, SSH key lookup, network snippet import,
rootfs growth, guest readiness, and the default yeet kernel package source.

## Publishing

Publishing is workflow-driven:

- `build-kernel.yml` builds and publishes canonical kernel assets.
- `publish-kernel-packages.yml` publishes the apt and Nix package sources.
- `build-ubuntu-26.04.yml` publishes Ubuntu image bundles.
- `build-nixos-26.05.yml` publishes NixOS image bundles.
- `sync-latest-stable-kernel.yml` checks for newer stable kernels and rebuilds
  stale image families.

The image workflows check out `yeetrun/yeet` at `yeet_ref`, build the guest
tools, consume a canonical kernel release or build a fallback kernel, build the
rootfs, verify the bundle, publish an immutable release, and optionally update
the latest alias used by catch.

### Firecracker Runtime Candidates

The `sync-latest-stable-firecracker.yml` workflow runs daily and can be started
manually. It discovers the newest official stable Firecracker release and calls
the local reusable `build-firecracker-runtime.yml` workflow only when that
upstream version has no verified immutable candidate release. All remote runtime
tag refs allocate packaging revisions, so a preserved tag or draft consumes its
`vN` and the next attempt uses `vN+1`. The scheduled workflow passes that exact
ID to the reusable workflow, which independently re-resolves it inside the
serialized job before building.

Before reporting a no-op, `verify-published-firecracker-runtime.sh` verifies the
published release identity and immutable state, its exact four asset records and
downloaded bytes, the runtime manifest schema and cross-field contract, and the
tag target against manifest provenance. A malformed or mutable matching release
is a failed discovery, not a no-op. A new candidate contains exactly
`firecracker`, `jailer`, `runtime-manifest.json`, and `runtime-checksums.txt`.
Publication emits GitHub's native `release: published` event for the Task 5
integration workflow; it does not send a second dispatch API request. The
workflow does not edit `runtime-catalog.json`.

Runtime publication requires two protected GitHub Environments:

- `firecracker-runtime-publish` protects every candidate publication and holds
  the environment-scoped `YEET_RUNTIME_GITHUB_APP_CLIENT_ID` variable and
  `YEET_RUNTIME_GITHUB_APP_PRIVATE_KEY` secret.
- `firecracker-runtime-overrides` adds a separate approval when an unsigned tag
  or signer rotation is explicitly requested. The normal
  `firecracker-runtime-publish` protection still applies afterward.

The GitHub App must be installed only on `yeetrun/yeet-vm-images` and grant the
repository permissions `Administration: read` and `Contents: write`. The
workflow mints a repository-scoped installation token with those same explicit
permissions and exposes it only to the publication step. There is no
personal-token or default `GITHUB_TOKEN` publication fallback. If App
configuration, protected environments, or reviewed signer material is missing,
the workflow fails before creating a runtime tag or release.
Before publication, repository immutable releases must be enabled; the publisher
checks that setting before it creates the immutable runtime tag.
The App credentials and scheduled publication remain disabled until the Task 5
integration workflow is present on `main` with both its native release consumer
and manual recovery entrypoint.

The fixed `firecracker-runtime-publish` concurrency group serializes automated
tag/release writes and never cancels an in-progress transaction. The trusted
repository boundary includes repository administrators because they can change
workflow and Environment configuration; this automation does not claim to
serialize independent administrator actions.

Runtime integration is tracked separately from candidate publication. The
`test-firecracker-runtime-kvm.yml` workflow accepts only an exact runtime ID and
manifest digest, exact immutable Ubuntu/NixOS guest and current/previous kernel
release IDs, and a full Yeet commit. It checks out that Yeet commit and requires
its repository-owned `scripts/test-firecracker-runtime-integration.sh` driver;
there is no runner-installed helper or direct-Firecracker fallback. The driver
lands with Catch runtime management, so `runtime-integration.json` is currently
a closed dormant gate: `enabled` is false and all release-event inputs are
null. Enabling it requires a reviewed commit that supplies every exact input.
Until then, native runtime release events are verified and reported without
scheduling a KVM runner, while a new manual recovery run can provide the exact
inputs after the driver exists.

A passed run publishes exactly `runtime-attestation.json` and
`runtime-attestation.sha256` in a new immutable
`<runtime-id>-integration-<run-id>` release. The attestation binds the runtime
digest, harness commit, tested Yeet commit, four immutable guest/kernel IDs, and
the passed evidence dimensions. Publication uses the protected
`firecracker-runtime-integration-publish` Environment and a repository-scoped
App token only for the immutable release transaction. A partial tag or draft is
preserved; recovery starts a new workflow run and therefore uses a new run ID.

Candidate listing is also deliberate. `promote-firecracker-runtime.yml`
re-verifies the immutable runtime and integration evidence, changes only
`runtime-catalog.json`, and opens `promote/<runtime-id>/candidate` as a reviewed
pull request. It never pushes to `main`, force-pushes, merges the PR, or changes
the stable pointer. The commit that adds this dormant machinery does not enable
credentials, protected Environments, a workflow run, or live KVM validation.

Detailed workflow inputs live in `.github/workflows/`. The README describes
the release model; the workflow files are the source of truth for dispatch
parameters.

Verification covers checksums, required kernel config values, embedded guest
tools, manifest metadata, package-source defaults, terminfo integration, and
image-family-specific rootfs policy.
