{ pkgs, ... }:

{
  # yeet seeds this to the VM service name when provisioning the rootfs.
  # Change it and rebuild to rename the guest.
  networking.hostName = "yeet-vm";

  # Add user-facing packages here. Yeet-required guest tools live in
  # yeet/vm.nix so the base VM contract stays intact.
  environment.systemPackages = with pkgs; [
    htop
    vim
  ];

  # Add VM-specific users, services, and application configuration here.
}
