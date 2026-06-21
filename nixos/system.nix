{ pkgs, ... }:

{
  # Change this when turning the base image into a named VM.
  networking.hostName = "yeet-vm";

  # Add user packages here rather than editing yeet/vm.nix.
  environment.systemPackages = with pkgs; [
  ];

  # Add VM-specific users, services, and application configuration here.
}
