# VM Image Repository Instructions

This repository builds and publishes official yeet VM image bundles.

## General Image Policy

- Keep each image compatible with its upstream distribution. Optimize by using
  the distribution's native mechanisms, not by rewriting fundamentals that
  package managers or system rebuild tools own.
- Yeet-owned integration points should stay explicit: Firecracker kernel,
  `yeet-init`, VM metadata files, readiness signaling, and bundle manifests.
- Rootfs customization should be reproducible from scripts or native build
  definitions. Do not rely on manual host state.
- Keep `README.md`, build validation, workflow defaults, and release notes
  aligned with intentional image policy changes.

## Ubuntu Compatibility

- Preserve Ubuntu package and filesystem contracts. Do not relocate
  package-owned files or replace package-owned directories unless Ubuntu's
  packaging system performs that change.
- Do not do cosmetic status cleanup by moving binaries between `/usr/bin`,
  `/usr/sbin`, `/bin`, or `/sbin`.
- Treat `systemctl status` taints as diagnostic signals. Classify the source
  first: yeet-caused failed units should be fixed, while upstream Ubuntu layout
  warnings may be documented or accepted.
- Optimize boot with compatible mechanisms: package removal, service masks,
  kernel config, yeet-owned init/readiness code, metadata, sysctls, and
  tmpfiles.

## NixOS Compatibility

- Build NixOS images the NixOS way: flake-pinned nixpkgs, NixOS modules, and a
  valid `/etc/nixos/configuration.nix`.
- Do not patch package-owned files in the rootfs to configure behavior. Express
  boot, networking, users, SSH, packages, and service defaults in the NixOS
  module so users can inspect and rebuild them normally.
- Keep yeet metadata data-only under `/etc/yeet-vm`; yeet may write hostname,
  SSH keys, and networkd snippets there, but NixOS services should decide how
  to consume them.
- Preserve `nixos-rebuild` compatibility. The shipped configuration should be a
  reasonable base users can extend rather than a hidden appliance image.
- Avoid preinstalling long-running application services unless they are part of
  the base VM contract. Users should enable software such as Tailscale through
  normal NixOS configuration.
