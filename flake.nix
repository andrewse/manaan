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
    in
    {
      nixosConfigurations = nixpkgs.lib.genAttrs hosts (
        name:
        nixpkgs.lib.nixosSystem {
          modules = hostModules name ++ [ { nixpkgs.hostPlatform = system; } ];
        }
      );

      formatter.${system} = pkgs.nixfmt;
    };
}
