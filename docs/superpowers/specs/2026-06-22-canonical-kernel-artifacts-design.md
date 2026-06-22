# Canonical Kernel Artifacts Design

## Context

The current latest-kernel automation builds the same yeet-managed Linux kernel in
each OS image workflow. Ubuntu and NixOS both run `scripts/build-linux-kernel.sh`
when the orchestrated workflow builds images for the same upstream kernel.

Kernel package publishing is also coupled to Ubuntu image releases. The package
workflow downloads `vmlinux` and `kernel.config` from an image release such as
`ubuntu-26.04-amd64-kernel-7.1.1-v18`, then writes apt and Nix metadata pointing
back at that Ubuntu release.

That works today, but it is the wrong artifact boundary. Kernel artifacts should
be canonical on their own. OS images should consume a known kernel artifact, and
kernel package metadata should point at the same kernel artifact instead of using
an Ubuntu image release as the source of truth.

## Goals

- Build each yeet-managed upstream kernel once per kernel release revision.
- Publish immutable canonical kernel releases that own `vmlinux`,
  `kernel.config`, manifest, and checksums.
- Make Ubuntu, NixOS, and kernel packages consume the same canonical kernel
  release.
- Remove the Ubuntu-image dependency from kernel package publishing.
- Preserve self-contained OS image bundles by continuing to include copied
  `vmlinux` and `kernel.config` assets in each image release.
- Preserve manual OS workflow usability by allowing local kernel builds when no
  canonical kernel release is supplied.
- Add a repo check that prevents references to the old `yeet[.]run` domain;
  this repository should use `yeetrun.com`.

## Non-Goals

- Do not remove kernel assets from OS image releases in this phase.
- Do not change guest kernel upgrade semantics.
- Do not change the apt or Nix package layout beyond changing their source
  assets and metadata provenance.
- Do not require every manual OS build to publish a canonical kernel release.

## Architecture

Introduce a first-class kernel release layer between latest-kernel detection and
OS image builds.

The canonical kernel release tag should be independent from image family tags:

- Kernel release: `kernel-linux-7.1.1-yeet-v1`
- Ubuntu image: `ubuntu-26.04-amd64-kernel-7.1.1-v19`
- NixOS image: `nixos-26.05-amd64-kernel-7.1.1-v7`

The kernel release owns:

- `vmlinux`
- `kernel.config`
- `kernel-manifest.json`
- checksum file

Ubuntu and NixOS image workflows accept an optional `kernel_release` input. When
present, they download and verify assets from that release instead of compiling
the kernel. They still copy those assets into the final image release so catch
can consume image bundles without separately resolving kernel releases.

Kernel package publishing accepts `kernel_release` and writes package metadata
whose URLs point to the canonical kernel release. Package metadata must not point
to an OS image release.

## Versioning

Kernel release revisions are separate from OS image revisions.

The kernel release revision increments when the same upstream kernel needs a new
canonical yeet kernel artifact, for example:

- the Firecracker base config URL changes;
- `scripts/build-linux-kernel.sh` changes required config or build behavior;
- the yeet local version policy changes;
- the resulting `vmlinux` or `kernel.config` checksum changes.

Image family revisions continue to increment when that OS image changes, whether
or not the kernel changes.

The kernel manifest should include:

- upstream kernel version;
- yeet kernel version, for example `linux-7.1.1-yeet`;
- Linux source URL and SHA256;
- Firecracker config URL;
- repository commit used for the build script;
- local version suffix;
- `vmlinux` SHA256;
- `kernel.config` SHA256;
- release tag.

Existing kernel releases are immutable. If a release tag already exists and its
manifest/checksums match the requested inputs, reuse it. If the tag exists but
does not match, fail and require a new kernel release revision.

## Workflow Design

`sync-latest-stable-kernel.yml` remains the orchestrator.

The intended dependency graph is:

1. Detect the latest stable upstream kernel and current catalog state.
2. Resolve the expected canonical kernel release for that upstream kernel and
   current yeet kernel inputs.
3. Build and publish the canonical kernel release only if it is missing.
4. Publish kernel packages from the canonical kernel release.
5. Build Ubuntu from the canonical kernel release.
6. Build NixOS from the canonical kernel release and the package metadata commit.

Ubuntu can run as soon as the canonical kernel release is available. NixOS must
wait for the package metadata commit so the shipped `/etc/nixos/flake.lock`
points at package metadata matching the selected kernel.

The manual OS workflows should support two modes:

- `kernel_release` present: download and verify canonical kernel assets.
- `kernel_release` absent: build the kernel locally as today.

## Component Changes

Add a reusable kernel workflow: `.github/workflows/build-kernel.yml`.
It should call `scripts/build-linux-kernel.sh`, validate the output, write
`kernel-manifest.json`, and publish the canonical kernel release.

Add a resolver script: `scripts/resolve-kernel-release.sh`.
It should compute the intended kernel release tag, detect whether the release
already exists, and find the next same-kernel revision when inputs changed.

Update `.github/workflows/publish-kernel-packages.yml`.
Replace `image_release` with `kernel_release`, download kernel assets from that
release, verify the manifest/checksums, and write `kernel-packages/metadata.nix`
URLs pointing to the kernel release.

Update `.github/workflows/build-ubuntu-26.04.yml` and
`.github/workflows/build-nixos-26.05.yml`.
Add optional `kernel_release` input and download/verify canonical assets when it
is supplied. Keep local kernel builds as the fallback path.

Update `sync-latest-stable-kernel.yml`.
Resolve or build the kernel release before OS/package jobs, pass `kernel_release`
to package publishing and OS builds, and pass the package metadata commit to the
NixOS workflow.

Update tests and documentation to describe canonical kernel releases, the manual
workflow fallback, and the new package provenance.

Update `packages/kernel/deb/DEBIAN/control.in`.
Change the remaining `yeet[.]run` maintainer reference to a `yeetrun.com`
identity, and add a test that rejects old-domain references in this repository.

## Validation

Static tests should assert:

- `publish-kernel-packages.yml` accepts `kernel_release` and no longer accepts
  `image_release`;
- generated `kernel-packages/metadata.nix` points at `kernel-linux-...` release
  assets;
- `sync-latest-stable-kernel.yml` resolves or builds a kernel release before
  package and OS image jobs;
- Ubuntu and NixOS workflows can consume a supplied `kernel_release`;
- the old `yeet[.]run` domain does not appear in tracked repository files.

Workflow verification should confirm:

- a new upstream kernel causes exactly one canonical kernel build;
- Ubuntu and NixOS releases built from that kernel have matching `vmlinux`
  checksums;
- kernel package metadata points to the canonical kernel release;
- a repeated run reuses the existing matching kernel release instead of
  rebuilding or mutating it.

Smoke verification should confirm:

- disposable Ubuntu and NixOS VMs boot from images built with the canonical
  kernel release;
- Ubuntu package upgrade flow still selects the package kernel and rebooting
  syncs it through the existing guest-to-host flow;
- NixOS rebuild via `sudo nixos-rebuild switch --flake /etc/nixos#yeet-vm`
  still keeps selected kernel metadata aligned with the image manifest.

## Rollout

Implement the canonical kernel workflow and package provenance change first,
then update OS workflows to consume the canonical release. Keep local kernel
build fallback paths until manual workflow users have a stable replacement.

After landing, trigger the latest-kernel workflow manually and verify the full
end-to-end path before cutting any release that depends on the new provenance
model.
