{
  description = "Official yeet VM image builds";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    yeet = {
      url = "github:yeetrun/yeet/main";
      flake = false;
    };
    yeet-vm-kernel = {
      url = "path:./kernel-packages";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-guest-config = {
      url = "path:./nixos";
      flake = false;
    };
  };

  outputs =
    { nixpkgs
    , yeet
    , yeet-vm-kernel
    , nixos-guest-config
    , ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      inherit (pkgs) lib;

      yeetInit = pkgs.rustPlatform.buildRustPackage {
        pname = "yeet-init";
        version = "0.1.0";
        src = "${yeet}/guest/yeet-init";
        cargoLock.lockFile = "${yeet}/guest/yeet-init/Cargo.lock";
        doCheck = false;
      };

      yeetAgent = pkgs.rustPlatform.buildRustPackage {
        pname = "yeet-agent";
        version = "0.1.0";
        src = "${yeet}/guest/yeet-agent";
        cargoLock.lockFile = "${yeet}/guest/yeet-agent/Cargo.lock";
        doCheck = false;
      };

      nixosSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./nixos/yeet/vm.nix
          yeet-vm-kernel.nixosModules.default
          ./nixos/system.nix
          {
            services.yeetVmKernel.enable = true;
            system.nixos.label = "26.05-yeet";
          }
        ];
      };

      nixosRootfs = import ./nix/make-ext4-rootfs.nix {
        inherit pkgs lib;
        inherit (pkgs)
          e2fsprogs
          fakeroot
          libfaketime
          perl
          zstd
          ;
        compressImage = false;
        inodeHeadroomPercent = 25;
        postMinimizeHeadroomMiB = 512;
        storePaths = [
          nixosSystem.config.system.build.toplevel
          yeetInit
          yeetAgent
        ];
        volumeLabel = "nixos";
        populateImageCommands = ''
          install -d -m 0755 \
            ./files/etc/nixos/yeet/assets \
            ./files/etc/yeet-vm/kernel \
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
          ln -s ${yeetAgent}/bin/yeet-agent ./files/usr/local/lib/yeet-vm/yeet-agent

          install -m 0644 ${nixos-guest-config}/README.md ./files/etc/nixos/README.md
          install -m 0644 ${nixos-guest-config}/flake.nix ./files/etc/nixos/flake.nix
          install -m 0644 ${nixos-guest-config}/flake.lock ./files/etc/nixos/flake.lock
          install -m 0644 ${nixos-guest-config}/system.nix ./files/etc/nixos/system.nix
          install -m 0644 ${nixos-guest-config}/yeet/vm.nix ./files/etc/nixos/yeet/vm.nix
          install -m 0644 ${nixos-guest-config}/yeet/assets/xterm-ghostty.terminfo ./files/etc/nixos/yeet/assets/xterm-ghostty.terminfo
          install -m 0644 ${nixosSystem.config.environment.etc."yeet-vm/kernel/selected.json".source} ./files/etc/yeet-vm/kernel/selected.json
        '';
      };
    in
    {
      nixosConfigurations.yeet-nixos-26_05 = nixosSystem;
      packages.${system} = {
        yeet-init = yeetInit;
        yeet-agent = yeetAgent;
        nixos-26_05-rootfs = nixosRootfs;
        default = nixosRootfs;
      };
    };
}
