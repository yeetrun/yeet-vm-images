# NixOS Flake Kernel Integration Implementation Plan

> **For shayne:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan.

**Goal:** make the official NixOS image ship a normal, flake-based `/etc/nixos` configuration that always enables the yeet VM kernel package source, writes the guest kernel selector during `nixos-rebuild`, and lets a guest `sudo reboot` pick up the new kernel through catch.

**Scope:**

- Replace the NixOS image's `/etc/nixos/configuration.nix` based entrypoint with `/etc/nixos/flake.nix`.
- Keep the yeet-owned base NixOS module inspectable under `/etc/nixos/yeet/vm.nix`.
- Ship a small `/etc/nixos/system.nix` user customization layer.
- Ship a real `/etc/nixos/flake.lock` so fresh rebuilds are reproducible.
- Make CI and local validation assert the new file layout and kernel selector behavior.
- Change kernel package publishing so the Nix source metadata on `main` advances when a new kernel package source is published.

**Out of scope:**

- No existing NixOS guest migration path. We have no deployed NixOS VMs.
- No Ubuntu image behavior change.
- No guest command like `yeet vm kernel ...`; the desired user flow is package manager or flake update, rebuild, reboot.

## Task 1: Add the guest flake layout

**Files:**

- `nixos/flake.nix`
- `nixos/system.nix`
- `nixos/README.md`
- `nixos/yeet/vm.nix`
- `nixos/yeet/assets/xterm-ghostty.terminfo`
- remove `nixos/configuration.nix`
- remove `nixos/yeet-vm.nix`
- remove `nixos/assets/xterm-ghostty.terminfo`

**Steps:**

1. Move the yeet base module and asset:

   ```bash
   mkdir -p nixos/yeet/assets
   git mv nixos/yeet-vm.nix nixos/yeet/vm.nix
   git mv nixos/assets/xterm-ghostty.terminfo nixos/yeet/assets/xterm-ghostty.terminfo
   rmdir nixos/assets
   git rm nixos/configuration.nix
   ```

2. Update `nixos/yeet/vm.nix`:

   - Change the terminfo path from `./assets/xterm-ghostty.terminfo` to the new relative path `./assets/xterm-ghostty.terminfo` after the move. This remains the same string because the asset moves with the module.
   - Remove `nixos-config=/etc/nixos/configuration.nix` from `nix.nixPath`.
   - Keep these Nix settings:

     ```nix
     nix.settings.experimental-features = [ "nix-command" "flakes" ];
     nix.nixPath = [
       "nixpkgs=${pkgs.path}"
     ];
     ```

   - Do not add `services.yeetVmKernel.enable` to this module. The image-owned flake wiring enables it unconditionally.

3. Add `nixos/flake.nix`:

   ```nix
   {
     description = "yeet NixOS VM";

     inputs = {
       nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
       yeet-vm-kernel.url = "github:yeetrun/yeet-vm-images?dir=kernel-packages";
       yeet-vm-kernel.inputs.nixpkgs.follows = "nixpkgs";
     };

     outputs = inputs@{ nixpkgs, yeet-vm-kernel, ... }: {
       nixosConfigurations.yeet-vm = nixpkgs.lib.nixosSystem {
         system = "x86_64-linux";
         specialArgs = { inherit inputs; };
         modules = [
           ./yeet/vm.nix
           yeet-vm-kernel.nixosModules.default
           ./system.nix
           {
             services.yeetVmKernel.enable = true;
           }
         ];
       };
     };
   }
   ```

4. Add `nixos/system.nix`:

   ```nix
   { pkgs, ... }:

   {
     networking.hostName = "yeet-vm";

     users.users.ubuntu = {
       description = "yeet VM user";
     };

     environment.systemPackages = with pkgs; [
     ];
   }
   ```

   Keep it intentionally small. Users extend this file for packages, services, users, and host-specific settings.

5. Add `nixos/README.md`:

   ```markdown
   # yeet NixOS VM

   This VM is managed as a flake.

   From `/etc/nixos`, rebuild with:

   ```bash
   sudo nixos-rebuild switch --flake .#yeet-vm
   ```

   To advance pinned inputs, run:

   ```bash
   sudo nix flake update --flake /etc/nixos
   sudo nixos-rebuild switch --flake /etc/nixos#yeet-vm
   sudo reboot
   ```

   `system.nix` is the user customization layer. `yeet/vm.nix` is the yeet base module.
   ```

6. Generate and commit an initial guest lock:

   ```bash
   nix --extra-experimental-features "nix-command flakes" flake lock --flake nixos
   ```

   Confirm `nixos/flake.lock` exists and pins `yeet-vm-kernel` as a GitHub input, not a tarball or local path.

## Task 2: Build the image from the same flake contract it ships

**Files:**

- `flake.nix`
- `flake.lock`

**Steps:**

1. Add a root build-time input for the local kernel package module:

   ```nix
   yeet-vm-kernel = {
     url = "path:./kernel-packages";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```

2. Add `yeet-vm-kernel` to the root output argument list:

   ```nix
   outputs = { self, nixpkgs, yeet, yeet-vm-kernel, ... }:
   ```

3. Replace the NixOS module list for `nixosSystem` with the shipped guest contract:

   ```nix
   modules = [
     ./nixos/yeet/vm.nix
     yeet-vm-kernel.nixosModules.default
     ./nixos/system.nix
     {
       services.yeetVmKernel.enable = true;
       system.nixos.label = "26.05-yeet";
     }
   ];
   ```

4. Update `populateImageCommands` to copy the new `/etc/nixos` files:

   ```sh
   mkdir -p ./etc/nixos/yeet/assets
   cp ${./nixos/README.md} ./etc/nixos/README.md
   cp ${./nixos/flake.nix} ./etc/nixos/flake.nix
   cp ${./nixos/flake.lock} ./etc/nixos/flake.lock
   cp ${./nixos/system.nix} ./etc/nixos/system.nix
   cp ${./nixos/yeet/vm.nix} ./etc/nixos/yeet/vm.nix
   cp ${./nixos/yeet/assets/xterm-ghostty.terminfo} ./etc/nixos/yeet/assets/xterm-ghostty.terminfo
   ```

5. Keep copying kernel assets and `boot.json` exactly as before.

6. Run:

   ```bash
   nix --extra-experimental-features "nix-command flakes" flake lock
   nix --extra-experimental-features "nix-command flakes" flake check
   ```

## Task 3: Make NixOS build preparation refresh the shipped guest lock

**Files:**

- `scripts/build-nixos-26.05.sh`

**Steps:**

1. Before the `nix build` command, compute the repository ref that should be pinned into the guest lock:

   ```bash
   if [[ -n "${YEET_VM_IMAGES_REF:-}" ]]; then
     guest_kernel_ref="${YEET_VM_IMAGES_REF}"
   else
     guest_kernel_ref="$(git rev-parse HEAD)"
   fi
   ```

2. Refresh `nixos/flake.lock` with the immutable kernel package source for that ref:

   ```bash
   nix --extra-experimental-features "nix-command flakes" flake lock \
     --flake nixos \
     --override-input yeet-vm-kernel "github:yeetrun/yeet-vm-images/${guest_kernel_ref}?dir=kernel-packages"
   ```

3. Print the pinned ref in build output:

   ```bash
   echo "Pinned guest yeet-vm-kernel input to ${guest_kernel_ref}"
   ```

4. Preserve local developer override support by allowing `YEET_VM_IMAGES_REF` to be set explicitly in CI and manual builds.

5. Do not use the GitHub Pages tarball in the shipped lock.

## Task 4: Commit kernel package metadata when publishing package sources

**Files:**

- `.github/workflows/publish-kernel-packages.yml`

**Steps:**

1. Ensure the workflow has:

   ```yaml
   permissions:
     contents: write
     pages: write
     id-token: write
   ```

2. After the existing metadata generation step, add a commit step:

   ```yaml
   - name: Commit Nix package metadata
     run: |
       set -euo pipefail
       git config user.name "github-actions[bot]"
       git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
       if ! git diff --quiet -- kernel-packages/metadata.nix; then
         git add kernel-packages/metadata.nix
         git commit -m "packages: update yeet VM kernel metadata"
         git push origin HEAD:main
       else
         echo "kernel-packages/metadata.nix already up to date"
       fi
   ```

3. Keep the Pages tarball publishing steps. That tarball remains a convenience artifact, but the shipped NixOS flake should pin the GitHub repo input.

4. Avoid committing generated Pages artifacts to `main`.

5. Run this workflow manually after implementation to prove it either commits new metadata or reports that metadata is already current.

## Task 5: Update local and CI validation

**Files:**

- `scripts/verify-nixos-26.05.sh`
- `.github/workflows/build-nixos-26.05.yml`
- `scripts/test-kernel-packages.sh`

**Steps:**

1. Replace old assertions for:

   - `/etc/nixos/configuration.nix`
   - `/etc/nixos/yeet-vm.nix`
   - `/etc/nixos/assets/xterm-ghostty.terminfo`
   - `nixos-config=/etc/nixos/configuration.nix`

2. Add assertions for:

   - `/etc/nixos/README.md`
   - `/etc/nixos/flake.nix`
   - `/etc/nixos/flake.lock`
   - `/etc/nixos/system.nix`
   - `/etc/nixos/yeet/vm.nix`
   - `/etc/nixos/yeet/assets/xterm-ghostty.terminfo`
   - no `/etc/nixos/configuration.nix`
   - `/etc/yeet-vm/kernel/selected.json`

3. In `scripts/verify-nixos-26.05.sh`, mount or inspect the rootfs and verify:

   ```bash
   grep -q 'nixosConfigurations.yeet-vm' "$mount_dir/etc/nixos/flake.nix"
   grep -q 'github:yeetrun/yeet-vm-images?dir=kernel-packages' "$mount_dir/etc/nixos/flake.nix"
   grep -q 'services.yeetVmKernel.enable = true;' "$mount_dir/etc/nixos/flake.nix"
   grep -q './yeet/vm.nix' "$mount_dir/etc/nixos/flake.nix"
   grep -q './system.nix' "$mount_dir/etc/nixos/flake.nix"
   test -f "$mount_dir/etc/yeet-vm/kernel/selected.json"
   test ! -e "$mount_dir/etc/nixos/configuration.nix"
   ```

4. In the GitHub Actions rootfs validation step, replace the old `test -f` paths with the new path list.

5. In `scripts/test-kernel-packages.sh`, add a check that `kernel-packages/flake.nix` still exposes `nixosModules.default` and writes `yeet-vm/kernel/selected.json`.

## Task 6: Update docs and release notes

**Files:**

- `README.md`
- `.github/workflows/build-nixos-26.05.yml`
- release note template text in any publishing workflow that mentions NixOS rebuilds

**Steps:**

1. Replace the old NixOS package-source instructions that use:

   ```nix
   inputs.yeet-vm-kernel.url = "tarball+https://yeetrun.github.io/yeet-vm-images/yeet-vm-kernel-flake.tar.gz";
   ```

   with the default guest flow:

   ```bash
   cd /etc/nixos
   sudo nix flake update
   sudo nixos-rebuild switch --flake .#yeet-vm
   sudo reboot
   ```

2. Document that the fresh image already includes:

   - `/etc/nixos/flake.nix`
   - `/etc/nixos/flake.lock`
   - `/etc/nixos/system.nix`
   - `/etc/nixos/yeet/vm.nix`
   - `services.yeetVmKernel.enable = true`

3. Document that `sudo reboot` is enough after a rebuild because catch reads the guest-selected kernel before Firecracker starts the VM again.

4. Keep the GitHub Pages tarball documented only as an advanced source for custom external flakes if we decide to keep mentioning it. Do not present it as the image default.

## Task 7: Run verification

**Commands:**

```bash
git status --short --branch
nix --extra-experimental-features "nix-command flakes" flake check
./scripts/test-kernel-packages.sh
./scripts/verify-nixos-26.05.sh
./scripts/build-nixos-26.05.sh
```

If `./scripts/build-nixos-26.05.sh` is too slow for the first pass, run it before any claim that the image behavior is complete.

**Rootfs checks after build:**

```bash
tmpdir="$(mktemp -d)"
sudo mount -o loop dist/nixos-26.05-amd64/rootfs.ext4 "$tmpdir"
test -f "$tmpdir/etc/nixos/flake.nix"
test -f "$tmpdir/etc/nixos/flake.lock"
test -f "$tmpdir/etc/nixos/system.nix"
test -f "$tmpdir/etc/nixos/yeet/vm.nix"
test -f "$tmpdir/etc/yeet-vm/kernel/selected.json"
test ! -e "$tmpdir/etc/nixos/configuration.nix"
sudo umount "$tmpdir"
rmdir "$tmpdir"
```

**Disposable VM smoke:**

1. Publish or locally register the new NixOS image bundle with yeet.
2. Start a disposable NixOS VM.
3. Inside the guest, run:

   ```bash
   cd /etc/nixos
   sudo nixos-rebuild switch --flake .#yeet-vm
   cat /etc/yeet-vm/kernel/selected.json
   sudo reboot
   ```

4. After reconnecting, confirm:

   ```bash
   uname -r
   test -f /etc/nixos/flake.lock
   test -f /etc/yeet-vm/kernel/selected.json
   ```

5. On the host, confirm catch logs show the selected guest kernel was synced before Firecracker started.

## Task 8: Land and push

**Steps:**

1. Review all diffs:

   ```bash
   git diff --stat
   git diff
   ```

2. Commit:

   ```bash
   git add .
   git commit -m "nixos: ship flake-based yeet kernel config"
   ```

3. Push `main`:

   ```bash
   git push origin main
   ```

4. Trigger and monitor relevant workflows:

   ```bash
   gh workflow run build-nixos-26.05.yml
   gh workflow run publish-kernel-packages.yml
   gh run list --limit 10
   ```

5. Do not mark complete until the workflow and disposable VM smoke evidence is recorded in the final response.
