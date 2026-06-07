{
  description = "Official yeet VM image builds";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    yeet = {
      url = "github:yeetrun/yeet/main";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      yeet,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      yeetInit = pkgs.rustPlatform.buildRustPackage {
        pname = "yeet-init";
        version = "0.1.0";
        src = "${yeet}/guest/yeet-init";
        cargoLock.lockFile = "${yeet}/guest/yeet-init/Cargo.lock";
        doCheck = false;
      };

      nixosSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./nixos/yeet-vm.nix
          {
            system.nixos.label = "26.05-yeet";
          }
        ];
      };

      nixosRootfs = import "${nixpkgs}/nixos/lib/make-ext4-fs.nix" {
        inherit pkgs lib;
        inherit (pkgs)
          e2fsprogs
          fakeroot
          libfaketime
          perl
          zstd
          ;
        compressImage = false;
        storePaths = [
          nixosSystem.config.system.build.toplevel
          yeetInit
        ];
        volumeLabel = "nixos";
        populateImageCommands = ''
          mkdir -p \
            ./files/etc/nixos/assets \
            ./files/etc/yeet-vm/systemd-network \
            ./files/nix/var/nix/gcroots \
            ./files/nix/var/nix/profiles \
            ./files/root \
            ./files/run \
            ./files/usr/local/lib/yeet-vm

          ln -s ${nixosSystem.config.system.build.toplevel} ./files/nix/var/nix/profiles/system-1-link
          ln -s system-1-link ./files/nix/var/nix/profiles/system
          ln -s /nix/var/nix/profiles/system ./files/nix/var/nix/gcroots/current-system
          ln -s /nix/var/nix/profiles/system ./files/run/current-system
          ln -s ${yeetInit}/bin/yeet-init ./files/usr/local/lib/yeet-vm/yeet-init

          cp ${./nixos/configuration.nix} ./files/etc/nixos/configuration.nix
          cp ${./nixos/yeet-vm.nix} ./files/etc/nixos/yeet-vm.nix
          cp ${./nixos/assets/xterm-ghostty.terminfo} ./files/etc/nixos/assets/xterm-ghostty.terminfo
        '';
      };
    in
    {
      nixosConfigurations.yeet-nixos-26_05 = nixosSystem;
      packages.${system} = {
        yeet-init = yeetInit;
        nixos-26_05-rootfs = nixosRootfs;
        default = nixosRootfs;
      };
    };
}
