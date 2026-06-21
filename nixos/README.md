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
