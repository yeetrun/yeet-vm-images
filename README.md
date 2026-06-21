# Yeet VM Images

This repository builds and publishes official yeet VM image bundles.

Official payloads:

- `vm://ubuntu/26.04`
- `vm://nixos/26.05`

Each bundle includes:

- `manifest.json`
- `vmlinux`
- `rootfs.ext4.zst`
- `firecracker`
- `kernel.config`
- `checksums.txt`

Ubuntu publishes both immutable version releases and a stable latest alias:

`https://github.com/yeetrun/yeet-vm-images/releases/download/ubuntu-26.04-amd64-latest/manifest.json`

NixOS publishes both immutable version releases and a stable latest alias:

`https://github.com/yeetrun/yeet-vm-images/releases/download/nixos-26.05-amd64-latest/manifest.json`

`catalog.json` is the source of truth for official VM image families. It maps
payloads such as `vm://ubuntu/26.04` to stable latest manifest URLs. Publishing
a new image version only updates the immutable release and the matching
`*-latest` release; edit `catalog.json` only when adding or changing a family.

## Automatic Kernel Refresh

The `Sync latest stable Linux kernel VM images` workflow runs daily and can
also be manually dispatched. It reads kernel.org latest stable metadata,
compares the Ubuntu and NixOS latest manifests, and only builds stale families.

Immutable versions use hybrid tags, such as
`ubuntu-26.04-amd64-kernel-7.1.1-v16`. The final `v<N>` remains the per-family
image revision, which allows revving image, rootfs, Firecracker, or guest
tooling changes without changing kernel. `*-latest` aliases and catalog
payloads remain stable.

## Guest Kernel Packages

The package source workflow publishes the same yeet-managed kernel artifacts as
guest-consumable package sources. Package installation is opt-in and writes a
data-only selector under `/etc/yeet-vm/kernel/selected.json`.

Ubuntu guests can add the apt source and install or upgrade the package:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://yeetrun.github.io/yeet-vm-images/apt/yeet-vm-kernel-archive-keyring.gpg | sudo tee /etc/apt/keyrings/yeet-vm-kernel-archive-keyring.gpg >/dev/null
sudo chmod 0644 /etc/apt/keyrings/yeet-vm-kernel-archive-keyring.gpg
printf 'Types: deb\nURIs: https://yeetrun.github.io/yeet-vm-images/apt\nSuites: stable\nComponents: main\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/yeet-vm-kernel-archive-keyring.gpg\n' | sudo tee /etc/apt/sources.list.d/yeet-vm-kernel.sources
sudo apt update
sudo apt install yeet-vm-kernel
```

NixOS guests use the yeet kernel package flake from this repository:

```nix
{
  inputs.yeet-vm-kernel.url = "github:yeetrun/yeet-vm-images?dir=kernel-packages";
}
```

```nix
{
  imports = [ inputs.yeet-vm-kernel.nixosModules.default ];
  services.yeetVmKernel.enable = true;
}
```

Fresh yeet NixOS images already enable that module through their shipped flake.
To update the selected kernel inside a NixOS guest:

```bash
cd /etc/nixos
sudo nix flake update
sudo nixos-rebuild switch --flake .#yeet-vm
sudo reboot
```

The guest package or rebuild only selects the desired kernel under
`/etc/yeet-vm/kernel/selected.json`. Firecracker still boots from a host-side
kernel path, so catch syncs the selected kernel at the guest reboot boundary
before starting the next Firecracker process. The fallback operator command is:

```bash
yeet vm kernel sync <service-name> --restart
```

## Ubuntu 26.04

The Ubuntu family is built from the official Ubuntu 26.04 cloud image, boots a
yeet-managed kernel under Firecracker direct kernel boot, uses
`/usr/local/lib/yeet-vm/yeet-init` as the pre-systemd init shim, includes
`yeet-agent` for live vsock network state queries, and omits `initrd.img`.

### Fast Profile

The default Ubuntu build profile is `fast`. It requires a kernel that already
has the Firecracker boot path built in. The kernel builder pins the
Firecracker microVM config revision used by yeet's no-initrd direct-boot image
and enables kernel IP autoconfiguration for the first VM interface. It also
builds in TUN, IPv6, seccomp, netfilter, conntrack, conntrack marks, nftables,
nft NAT/masquerade, and the nft compatibility support needed by Ubuntu's
`iptables-nft` userspace so guest-installed router software and in-guest Nix
builds have the kernel features they need without depending on loadable kernel
modules. The kernel still enables module-loader support so distro activation
paths that manage `/proc/sys/kernel/modprobe` keep working normally:

```bash
scripts/build-linux-kernel.sh dist/kernel-linux-7.0
cd ../yeet
mise run guest:init:build
mise run guest:agent:build
cd ../yeet-vm-images
sudo YEET_VM_KERNEL_PATH="$PWD/dist/kernel-linux-7.0/vmlinux" \
  YEET_VM_KERNEL_VERSION=linux-7.0-yeet \
  YEET_VM_INIT_PATH="$PWD/../yeet/guest/yeet-init/target/x86_64-unknown-linux-musl/release/yeet-init" \
  YEET_VM_AGENT_PATH="$PWD/../yeet/guest/yeet-agent/target/x86_64-unknown-linux-musl/release/yeet-agent" \
  scripts/build-ubuntu-26.04.sh
```

The Ubuntu builder uses `assets/xterm-ghostty.terminfo` by default. Set
`YEET_VM_GHOSTTY_TERMINFO` only when testing a different terminfo source.

The fast profile customizes the Ubuntu rootfs before compression:

- purges Ubuntu kernel, module, header, bootloader, initramfs, and snap
  packages;
- writes `/etc/apt/preferences.d/99-yeet-managed-kernel` to keep those packages
  from returning during guest apt upgrades;
- writes `/usr/share/doc/yeet-vm-image/kernel.md` explaining that the boot
  kernel is supplied by the yeet VM image bundle and that nftables-oriented
  router kernel features are built in rather than loaded as modules;
- writes `/usr/share/doc/yeet-vm-image/init.md` explaining the pre-systemd
  `yeet-init` path and readiness flow;
- installs the Rust `yeet-init` binary into `/usr/local/lib/yeet-vm/yeet-init`;
- installs `/usr/local/lib/yeet-vm/yeet-agent` and enables
  `yeet-agent.service` so catch can query current guest network state over
  Firecracker vsock;
- compiles Ghostty's `xterm-ghostty` terminfo into `/etc/terminfo` so terminal
  applications recognize that TERM value out of the box;
- keeps `iptables`, `nftables`, and `rsync` userspace tools installed for
  guest-managed firewalls, routers, and `yeet copy` guest file sync. On Ubuntu,
  the default `iptables` command uses the nftables backend;
- writes `/etc/sysctl.d/99-yeet-vm-router.conf` with IPv4 and IPv6 forwarding
  enabled;
- writes `/etc/tmpfiles.d/yeet-vm-tun.conf` so `/dev/net/tun` is present for
  guest-managed tunneling software;
- enables kernel IP autoconfiguration for the first VM interface;
- uses systemd-networkd and `yeet-sshd.service` instead of netplan and the
  stock `ssh.service` for VM readiness;
- purges cloud-init, pollinate, fwupd, update-notifier, xfsprogs, netplan,
  networkd-dispatcher, chrony, sysstat, plymouth, console keyboard setup, and
  other server-image services that do not contribute to yeet VM boot;
- masks residual boot units for netplan, networkd-dispatcher, sysstat,
  e2scrub, XFS scrub, fwupd refresh, update notifier, binfmt_misc, ldconfig,
  keyboard setup, plymouth, module loading, and background maintenance timers;
- preserves Ubuntu package-owned filesystem paths such as `/usr/sbin` so normal
  Ubuntu packages and alternatives keep working inside yeet VMs;
- normalizes the root filesystem to a conservative ext4 feature set so common
  LTS host tooling can check, resize, and mount VM disks during provisioning;
- masks snapd units because the fast image intentionally does not support
  snaps.

The fast profile does not preinstall Tailscale or any other overlay network
agent. Users can install and manage those services inside the VM using normal
Ubuntu packages.

### Stock Profile

For debugging or reproducing the old v1-style image, use the stock profile:

```bash
YEET_VM_IMAGE_PROFILE=stock \
  YEET_VM_IMAGE_VERSION=ubuntu-26.04-amd64-v1 \
  scripts/build-ubuntu-26.04.sh
```

The stock profile extracts Ubuntu's generic kernel from the cloud image and
includes `initrd.img`. It does not apply the yeet-managed kernel or no-snap
rootfs policy.

## NixOS 26.05

The NixOS bundle is built from a flake-pinned `nixpkgs` input using NixOS
modules. It boots the same yeet-managed Firecracker kernel and uses the same
Rust `yeet-init` pre-systemd shim as Ubuntu, but the guest operating system is
configured through normal NixOS declarations.

NixOS image metadata:

- `default_user`: `nixos`
- `metadata_driver`: `nixos`
- `guest_init`: `/usr/local/lib/yeet-vm/yeet-init`
- `guest_agent`: `/usr/local/lib/yeet-vm/yeet-agent`
- `guest_system_init`: `/run/current-system/init`

The NixOS module:

- keeps `/etc/nixos/flake.nix`, `/etc/nixos/flake.lock`,
  `/etc/nixos/system.nix`, and `/etc/nixos/yeet/vm.nix` in the guest so users
  can inspect and rebuild the system normally with
  `sudo nixos-rebuild switch --flake /etc/nixos#yeet-vm` or, from
  `/etc/nixos`, `sudo nixos-rebuild switch --flake .#yeet-vm`;
- enables the yeet VM kernel selector by default through
  `services.yeetVmKernel.enable = true`, writing
  `/etc/yeet-vm/kernel/selected.json` for catch to sync at the next guest
  reboot boundary;
- uses systemd-networkd and copies yeet-provided network snippets from
  `/etc/yeet-vm/systemd-network` into `/run/systemd/network` at boot;
- uses `/etc/nixos/system.nix` as the durable VM hostname source after yeet
  seeds it during provisioning, falling back to `/etc/yeet-vm/hostname` for
  unseeded images;
- reads SSH authorized keys from `/etc/yeet-vm/authorized_keys.d/%u` through
  the NixOS OpenSSH `authorizedKeysFiles` option;
- grows the ext4 root filesystem at boot before yeet reports guest readiness,
  so ZFS-backed clones use the requested VM disk size;
- enables `yeet-agent.service` so catch can query current guest network state
  over Firecracker vsock;
- disables Firecracker-inapplicable static `modprobe@...` startup units and
  clears upstream generic hardware module requests because yeet kernels build
  the microVM drivers in and the image does not ship a module tree;
- keeps yeet-owned boot, readiness, SSH, sync, network, and package-source
  tooling in `yeet/vm.nix`, including `rclone`, `rsync`, `iptables`,
  `nftables`, `curl`, `git`, `jq`, `openssh`, and related base tools;
- keeps `/etc/nixos/system.nix` as the user-additive layer, seeded only with
  starter admin tools such as `htop` and `vim`;
- provides `/dev/net/tun` through tmpfiles for guest-managed tunnel software.

The NixOS image does not preinstall Tailscale or other application services.
Users who want Tailscale should enable it through their NixOS configuration,
for example with `services.tailscale.enable = true;`, then rebuild the system
inside the VM.

Local build:

```bash
scripts/build-linux-kernel.sh dist/kernel-linux-7.0
YEET_VM_KERNEL_PATH="$PWD/dist/kernel-linux-7.0/vmlinux" \
  YEET_VM_KERNEL_VERSION=linux-7.0-yeet \
  YEET_SOURCE_PATH="$PWD/../yeet" \
  scripts/build-nixos-26.05.sh
```

Local Nix checks:

```bash
mise run lint
YEET_SOURCE_PATH="$PWD/../yeet" scripts/verify-nixos-26.05.sh
```

`mise run lint` runs `deadnix`, `nixpkgs-fmt --check`, and `statix check`
against the flake and NixOS module. The verifier checks the yeet microVM
profile, service wiring, metadata integration, rebuild defaults, terminfo
integration, guest tool packaging, and user overrideability. Set
`YEET_SOURCE_PATH` while testing yeet changes that have not reached the
`flake.lock` yeet input yet.

## Publish a New Bundle

### Ubuntu

Use the **Build Ubuntu 26.04 VM image** GitHub Actions workflow from the
Actions tab. It is manually dispatched and runs on a GitHub-hosted Linux
runner. The workflow checks out yeet at `yeet_ref`, builds the Rust
`yeet-init` and `yeet-agent` guest tools, builds the managed kernel,
customizes the Ubuntu rootfs, verifies the bundle, and publishes the release
assets.

Inputs:

- `version`: release and image version, usually
  `ubuntu-26.04-amd64-kernel-<kernel>-v<N>`; legacy
  `ubuntu-26.04-amd64-v<N>` releases remain valid
- `yeet_ref`: yeet repository ref used to build `guest/yeet-init` and
  `guest/yeet-agent`
- `ubuntu_cloud_base_url`: Ubuntu cloud image directory URL
- `ubuntu_cloud_image`: Ubuntu cloud image tarball name
- `firecracker_version`: Firecracker release version
- `kernel_version`: Linux kernel version to build
- `upstream_kernel_version`: official upstream Linux kernel version recorded in
  the manifest
- `image_revision`: numeric per-family image revision; it must match the final
  `v<N>` suffix when the version includes one
- `kernel_source_url`: Linux kernel source tarball URL
- `kernel_source_sha256`: Linux kernel source tarball SHA-256
- `kernel_config_url`: Firecracker guest kernel config URL used as the build
  baseline. The default is pinned to the Firecracker microVM config revision
  used by yeet's no-initrd direct-boot image.
- `zstd_level`: compression level for `rootfs.ext4.zst`
- `overwrite_release`: delete an existing release/tag with the same version
  before publishing
- `publish_latest_alias`: update the stable Ubuntu latest alias after
  publishing the immutable version release
- `latest_alias`: release/tag name for the catch-facing latest alias

The workflow validates `checksums.txt`, confirms the fast image has no
`initrd.img`, checks the required kernel config values, verifies the embedded
`yeet-init` and `yeet-agent`, terminfo, router rootfs defaults,
Ubuntu-compatible package paths, host-compatible ext4 rootfs features, and
guest tool manifest metadata, prints the manifest, and publishes the release
assets.

### NixOS

Use the **Build NixOS 26.05 VM image** GitHub Actions workflow. It checks out
yeet at `yeet_ref`, builds the managed kernel, builds the NixOS rootfs from the
flake, verifies the bundle, publishes an immutable version release, and can
also update the `nixos-26.05-amd64-latest` release alias used by catch.

Inputs:

- `version`: release and image version, usually
  `nixos-26.05-amd64-kernel-<kernel>-v<N>`; legacy
  `nixos-26.05-amd64-v<N>` releases remain valid
- `yeet_ref`: yeet repository ref used to build `guest/yeet-init` and
  `guest/yeet-agent`
- `kernel_version`: Linux kernel version to build
- `upstream_kernel_version`: official upstream Linux kernel version recorded in
  the manifest
- `image_revision`: numeric per-family image revision; it must match the final
  `v<N>` suffix when the version includes one
- `kernel_source_url`: Linux kernel source tarball URL
- `kernel_source_sha256`: Linux kernel source tarball SHA-256
- `kernel_config_url`: Firecracker guest kernel config URL used as the build
  baseline
- `firecracker_version`: Firecracker release version
- `zstd_level`: compression level for `rootfs.ext4.zst`
- `overwrite_release`: delete an existing release/tag with the same version
  before publishing
- `publish_latest_alias`: update the stable NixOS latest alias after publishing
  the immutable version release
- `latest_alias`: release/tag name for the catch-facing latest alias

The workflow validates the NixOS microVM profile, checks `checksums.txt`,
checks the required kernel config values, verifies NixOS system links, confirms
the embedded `yeet-init` and `yeet-agent`, checks the Ghostty terminfo source,
verifies NixOS manifest metadata, prints the manifest, and publishes the
release assets.
