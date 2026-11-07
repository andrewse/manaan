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

      # Shared by the real machine and its VM test, so the test boots the same config.
      hostModules = name: [
        disko.nixosModules.disko
        agenix.nixosModules.default
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

      checks = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        forHosts (
          name:
          {
            ${name} = import ./tests/host.nix {
              inherit pkgs name;
              modules = hostModules name;
            };
          }
          # Its QEMU command is written for x86_64 only, for now.
          // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
            # Installs the host from its ISO and upgrades it. The systems it installs have
            # the VM test overrides and the test driver's backdoor, so the test can
            # inspect them after each reboot.
            "${name}-lifecycle" = import ./tests/lifecycle.nix {
              inherit pkgs name;
              mkHost = mkHost system;
              mkInstaller = mkInstaller system;
              modules = hostModules name ++ [
                ./tests/vm.nix
                "${nixpkgs}/nixos/modules/testing/test-instrumentation.nix"
              ];
            };
          }
        )
        // import ./tests/scripts.nix { inherit pkgs; }
      );

      formatter = forSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
