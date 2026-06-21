{
  description = "yeet VM kernel package source";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs
    , ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      metadata = import ./metadata.nix;
      kernelLabel = "linux-${metadata.kernelVersion}-yeet";
      vmlinux = metadata.vmlinuxPath or (pkgs.fetchurl {
        url = metadata.vmlinuxUrl;
        hash = metadata.vmlinuxHash;
      });
      kernelConfig = metadata.kernelConfigPath or (pkgs.fetchurl {
        url = metadata.kernelConfigUrl;
        hash = metadata.kernelConfigHash;
      });
      kernelPackage = pkgs.callPackage ./yeet-kernel-package.nix {
        inherit vmlinux kernelConfig;
        inherit (metadata) kernelVersion vmlinuxSha256Raw kernelConfigSha256Raw;
      };
    in
    {
      packages.${system}.default = kernelPackage;
      nixosModules.default =
        { config
        , lib
        , ...
        }:
        {
          options.services.yeetVmKernel.enable = lib.mkEnableOption "yeet VM kernel selector";
          config = lib.mkIf config.services.yeetVmKernel.enable {
            environment.systemPackages = [ kernelPackage ];
            environment.etc."yeet-vm/kernel/selected.json".source =
              "${kernelPackage}/share/yeet-vm/kernel/selected.json";
            system.activationScripts.yeet-vm-kernel-sync-message.text = ''
              printf '%s\n' \
                "" \
                "yeet VM kernel ${kernelLabel} selected." \
                "" \
                "Reboot this VM to boot the selected kernel." \
                "" >&2
            '';
          };
        };
    };
}
