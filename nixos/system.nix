{ pkgs, ... }:

{
  # yeet seeds this to the VM service name when provisioning the rootfs.
  # Change it and rebuild to rename the guest.
  networking.hostName = "yeet-vm";

  # yeet/catch guest workflows expect these packages. Remove only if you do
  # not use those features.
  environment.systemPackages = with pkgs; [
    rclone
    rsync

    iptables
    nftables

    # Useful starter tools. Safe to prune or replace.
    curl
    file
    gitMinimal
    htop
    iproute2
    jq
    openssh
    procps
    vim
    wget
  ];

  # Add VM-specific users, services, and application configuration here.
}
