# NixOS Flake Kernel Integration Design

## Summary

The official yeet NixOS image should be flake-first and should integrate the
published `yeet-vm-kernel` flake by default. A fresh NixOS guest should have a
real `/etc/nixos/flake.nix`, a pinned `/etc/nixos/flake.lock`, a small
user-owned `/etc/nixos/system.nix`, and yeet-owned support files under
`/etc/nixos/yeet/`.

The supported update flow should feel like normal NixOS flake maintenance:

```bash
cd /etc/nixos
sudo nix flake update
sudo nixos-rebuild switch --flake .#yeet-vm
sudo reboot
```

The rebuild selects the yeet-managed Firecracker kernel by writing
`/etc/yeet-vm/kernel/selected.json`. On guest reboot, catch syncs that selected
kernel from the guest rootfs into the host-side VM runtime directory and starts
Firecracker with the updated kernel.

## Goals

- Make `/etc/nixos/flake.nix` the default and documented NixOS system
  entrypoint.
- Ship `/etc/nixos/flake.lock` so fresh VM rebuilds are reproducible until the
  user intentionally updates the lock.
- Enable the `yeet-vm-kernel` NixOS module by default, without asking users to
  copy module snippets into their config.
- Keep user-facing customization in `/etc/nixos/system.nix`.
- Keep yeet-owned implementation files under `/etc/nixos/yeet/`.
- Remove the old `configuration.nix` entrypoint from new NixOS images.

## Non-goals

- Do not preserve `sudo nixos-rebuild switch` without `--flake` as a supported
  path for new NixOS images.
- Do not add migration logic for existing NixOS VMs; none are currently deployed.
- Do not change Ubuntu guest kernel package behavior.
- Do not change catch's guest reboot kernel sync design in this pass.

## Guest Filesystem Layout

The image should populate these files:

```text
/etc/nixos/
  flake.nix
  flake.lock
  system.nix
  README.md
  yeet/
    vm.nix
    assets/
      xterm-ghostty.terminfo
```

`flake.nix` is mostly wiring. It declares `nixpkgs` and `yeet-vm-kernel`
inputs, then exposes `nixosConfigurations.yeet-vm`. The shipped image should
use a Git-revisioned `yeet-vm-kernel` input, not a mutable Pages tarball input,
so locked rebuilds keep working after newer kernel package sources are
published.

`system.nix` is the user customization layer. It should contain practical,
small defaults and comments for common edits such as hostname, packages, users,
and services.

`yeet/vm.nix` is the yeet-owned base VM module. It contains the current NixOS VM
contract: direct Firecracker boot assumptions, root filesystem settings,
networkd metadata ingestion, OpenSSH key metadata, grow-root, `yeet-agent`,
readiness signaling, terminfo, and microVM package defaults.

`README.md` is a short human breadcrumb that documents the flake workflow and
states that `system.nix` is the intended customization file.

`configuration.nix` should not be shipped in new NixOS images.

## Flake Module Order

`flake.nix` should import modules in this order:

```nix
[
  ./yeet/vm.nix
  inputs.yeet-vm-kernel.nixosModules.default
  ./system.nix
  {
    services.yeetVmKernel.enable = true;
  }
]
```

The order keeps ownership clear:

- `yeet/vm.nix` defines the base image contract.
- `yeet-vm-kernel` provides the selector package and
  `/etc/yeet-vm/kernel/selected.json`.
- `system.nix` is loaded after the base module so users can override normal
  settings.
- `services.yeetVmKernel.enable = true` is applied after `system.nix` because
  kernel selection is part of the yeet VM contract and should not be presented
  as a normal customization knob.

## Build-time Locking

The image build must generate and ship a real `/etc/nixos/flake.lock`.

The lock should pin:

- the same `nixpkgs` revision used to build the image rootfs;
- a `yeet-vm-kernel` flake input from this repository's `kernel-packages`
  directory at the commit that describes the image's boot kernel.

Use a Git input shape like this in the guest flake:

```nix
inputs.yeet-vm-kernel.url = "github:yeetrun/yeet-vm-images?dir=kernel-packages";
```

The resulting lock pins a Git revision and nar hash. That is stable for fresh
rebuilds, while `sudo nix flake update` moves the guest to the latest committed
kernel package metadata.

The package source workflow should commit the generated
`kernel-packages/metadata.nix` update to `main` when publishing a new kernel
package source. The metadata should point at immutable GitHub release assets for
`vmlinux` and `kernel.config`. The GitHub Pages tarball can continue to exist as
a convenience source, but the shipped NixOS image should not depend on a mutable
Pages tarball in its lock.

The shipped lock must ensure a fresh VM rebuild does not silently switch
kernels until the user runs `nix flake update`.

## User Workflow

Fresh rebuild without changing inputs:

```bash
cd /etc/nixos
sudo nixos-rebuild switch --flake .#yeet-vm
```

Kernel and package-source update:

```bash
cd /etc/nixos
sudo nix flake update
sudo nixos-rebuild switch --flake .#yeet-vm
sudo reboot
```

The reboot is required because Firecracker boots a host-side kernel. The NixOS
rebuild selects the desired kernel inside the guest; catch syncs that selection
at the guest reboot boundary.

## Runtime Kernel Selection

The `yeet-vm-kernel` package writes a selector like:

```json
{
  "schema_version": 1,
  "version": "linux-7.1.1-yeet",
  "kernel": "/nix/store/.../lib/yeet-vm/kernels/linux-7.1.1-yeet/vmlinux",
  "kernel_config": "/nix/store/.../lib/yeet-vm/kernels/linux-7.1.1-yeet/kernel.config",
  "sha256": {
    "vmlinux": "...",
    "kernel.config": "..."
  }
}
```

Catch already owns the host-side sync path. On guest reboot it mounts the rootfs,
resolves the selector paths, verifies checksums, copies `vmlinux` and
`kernel.config` into the host service runtime kernel cache, rewrites
`firecracker.json`, and starts the VM with the selected kernel.

If the selector is absent, catch keeps the existing host-side kernel behavior.

## Documentation

Update README and release notes to state:

- NixOS images are flake-first.
- `/etc/nixos/system.nix` is the user customization file.
- `/etc/nixos/yeet/` is yeet-owned and normally inspected rather than edited.
- The supported rebuild command is
  `sudo nixos-rebuild switch --flake .#yeet-vm` from `/etc/nixos`.
- The supported kernel update flow is `sudo nix flake update`, rebuild, and
  reboot.
- `configuration.nix` is intentionally absent in the new image contract.

## Verification

Static checks:

- The rootfs population copies `flake.nix`, `flake.lock`, `system.nix`,
  `README.md`, `yeet/vm.nix`, and supporting assets.
- No `/etc/nixos/configuration.nix` is shipped.
- The flake imports `inputs.yeet-vm-kernel.nixosModules.default`.
- The flake enables `services.yeetVmKernel`.

Nix evaluation checks:

- Evaluate `nixosConfigurations.yeet-vm`.
- Assert `services.yeetVmKernel.enable = true`.
- Assert `/etc/yeet-vm/kernel/selected.json` exists in the evaluated system
  configuration.
- Preserve existing image invariants: `yeet-agent`, OpenSSH metadata keys,
  networkd metadata ingestion, grow-root, no bootloader, no initrd, cleared
  Firecracker-inapplicable module requests, and flakes enabled.

Disposable VM smoke test:

- Boot a fresh NixOS VM.
- Confirm `/etc/nixos/flake.nix`, `/etc/nixos/flake.lock`,
  `/etc/nixos/system.nix`, `/etc/nixos/README.md`, and
  `/etc/nixos/yeet/vm.nix` exist.
- Confirm `sudo nixos-rebuild switch --flake /etc/nixos#yeet-vm` succeeds.
- Update the lock to a known newer `yeet-vm-kernel`, rebuild, verify
  `/etc/yeet-vm/kernel/selected.json`, reboot, and confirm `uname -r` matches
  the selected kernel.

## Rollout

This is a greenfield NixOS image contract change. Existing Ubuntu VMs and
existing catch hosts do not require migration. New NixOS image releases should
carry the flake-first contract and should be smoke-tested before catalog aliases
move to the new image.
