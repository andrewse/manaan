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
      # What the machines run. The tests also build for aarch64-linux, so they can
      # run without emulating another architecture on an Apple Silicon Mac.
      system = "x86_64-linux";
      forSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
      hosts = builtins.attrNames (
        nixpkgs.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
      );

      machineLib =
        { pkgs, ... }:
        {
          _module.args.machineLib = import ./lib { inherit pkgs; };
        };

      # Shared by the real machine and its VM test, so the test boots the same config.
      hostModules = name: [
        disko.nixosModules.disko
        agenix.nixosModules.default
        machineLib
        ./modules
        ./hosts/${name}
        { networking.hostName = name; }
      ];
      mkHost =
        system: modules:
        nixpkgs.lib.nixosSystem {
          modules = modules ++ [ { nixpkgs.hostPlatform = system; } ];
        };

      # An ISO that installs `target` (a nixosSystem) onto a blank disk at boot.
      mkInstaller =
        system: target:
        mkHost system [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          machineLib
          ./installer
          { machine.installer.target = target; }
        ];

      forHosts = f: nixpkgs.lib.mergeAttrsList (map f hosts);
    in
    {
      nixosConfigurations = nixpkgs.lib.genAttrs hosts (name: mkHost system (hostModules name));

      packages.${system} = forHosts (name: {
        "${name}-installer" =
          (mkInstaller system self.nixosConfigurations.${name}).config.system.build.isoImage;
      });

      # Three categories, by prefix: unit-* (one script or module on its own),
      # integration-* (several together, still with nothing outside the
      # sandbox) and system-* (a host in VMs). `make test-<category>` runs one.
      checks = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./tests/unit.nix {
          inherit pkgs;
          evalModules =
            modules:
            (mkHost system (
              [
                machineLib
                { system.stateVersion = nixpkgs.lib.trivial.release; }
              ]
              ++ modules
            )).config;
        }
        // import ./tests/integration {
          inherit pkgs;
          hosts = self.nixosConfigurations;
        }
        // forHosts (name: {
          "system-${name}" = import ./tests/system/host.nix {
            inherit pkgs name;
            modules = hostModules name;
          };
          "system-${name}-installer" = import ./tests/system/installer.nix {
            inherit pkgs name;
            modules = hostModules name;
            mkInstaller = mkInstaller system;
          };
          "system-${name}-upgrade" = import ./tests/system/upgrade.nix {
            inherit pkgs name;
            modules = hostModules name;
            mkHost = mkHost system;
            mkInstaller = mkInstaller system;
          };
        })
      );

      # The unit and integration checks as one derivation each, for `make
      # test-unit` and `make test-integration`: `nix build .#tests.unit`.
      legacyPackages = forSystems (system: {
        tests = nixpkgs.lib.genAttrs [ "unit" "integration" ] (
          category:
          nixpkgs.legacyPackages.${system}.linkFarmFromDrvs "test-${category}" (
            nixpkgs.lib.attrValues (
              nixpkgs.lib.filterAttrs (name: _: nixpkgs.lib.hasPrefix "${category}-" name) self.checks.${system}
            )
          )
        );
      });

      formatter = forSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
