# A host's whole configuration, every module together, as it ships: the
# promises one module makes that only hold if the others keep them. Evaluated,
# not built or booted. Cases for one host alone are in <host>.nix beside this.
{
  lib,
  name,
  config,
}:

let
  args = { inherit lib config; };
in
import ./security.nix args
// import ./services.nix args
// lib.optionalAttrs (builtins.pathExists ./${name}.nix) (import ./${name}.nix args)
