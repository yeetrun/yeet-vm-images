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
