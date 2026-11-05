{
  description = "Deterministic machine configurations, pulled by each machine from the release branch";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hosts = builtins.attrNames (
        nixpkgs.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
      );

      # Shared by the real machine and its VM test, so the test boots the same config.
      hostModules = name: [
        disko.nixosModules.disko
        agenix.nixosModules.default
        ./modules
        ./hosts/${name}
        { networking.hostName = name; }
      ];
      mkHost =
        modules:
        nixpkgs.lib.nixosSystem {
          modules = modules ++ [ { nixpkgs.hostPlatform = system; } ];
        };

      # An ISO that installs `target` (a nixosSystem) onto a blank disk at boot.
      mkInstaller =
        target:
        mkHost [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./installer
          { machine.installer.target = target; }
        ];

      forHosts = f: nixpkgs.lib.mergeAttrsList (map f hosts);
    in
    {
      nixosConfigurations = nixpkgs.lib.genAttrs hosts (name: mkHost (hostModules name));

      packages.${system} = forHosts (name: {
        "${name}-installer" = (mkInstaller self.nixosConfigurations.${name}).config.system.build.isoImage;
      });

      checks.${system} = forHosts (name: {
        ${name} = import ./tests/host.nix {
          inherit pkgs name;
          modules = hostModules name;
        };
        # Same installer, but the system it installs has the VM test overrides and
        # the test driver's backdoor so the test can inspect it after it reboots.
        "${name}-installer" = import ./tests/installer.nix {
          inherit pkgs name;
          installer = mkInstaller (
            mkHost (
              hostModules name
              ++ [
                ./tests/vm.nix
                "${nixpkgs}/nixos/modules/testing/test-instrumentation.nix"
              ]
            )
          );
        };
      });

      formatter.${system} = pkgs.nixfmt;
    };
}
