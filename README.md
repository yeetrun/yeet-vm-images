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

Detailed workflow inputs live in `.github/workflows/`. The README describes
the release model; the workflow files are the source of truth for dispatch
parameters.

Verification covers checksums, required kernel config values, embedded guest
tools, manifest metadata, package-source defaults, terminfo integration, and
image-family-specific rootfs policy.
