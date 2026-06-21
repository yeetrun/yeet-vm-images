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
      vmlinux = pkgs.fetchurl {
        url = metadata.vmlinuxUrl;
        hash = metadata.vmlinuxHash;
      };
      kernelConfig = pkgs.fetchurl {
        url = metadata.kernelConfigUrl;
        hash = metadata.kernelConfigHash;
      };
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
              service_name="<service-name>"
              hostname_file="/etc/yeet-vm/hostname"
              if [ -r "$hostname_file" ]; then
                IFS= read -r service_name <"$hostname_file" || service_name="<service-name>"
              fi

              case "$service_name" in
                "" | *[!A-Za-z0-9._-]*)
                  service_name="<service-name>"
                  ;;
              esac

              printf '%s\n' \
                "" \
                "yeet VM kernel ${kernelLabel} selected." \
                "" \
                "Firecracker boots this VM from a host-side kernel path. To boot this selected" \
                "kernel, run from your yeet client:" \
                "" \
                "  yeet vm kernel sync $service_name --restart" \
                "" >&2
            '';
          };
        };
    };
}
