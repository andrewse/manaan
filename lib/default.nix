# Functions shared by the modules and the installer, given to each as the
# `machineLib` argument (see flake.nix).
{ pkgs }:

let
  inherit (pkgs) lib;
in
{
  # A shell script put together the way the script tests run it: its shell
  # variables, then each part in order, a file to read or a string.
  mkScript =
    {
      name,
      runtimeInputs,
      vars ? { },
      parts,
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text =
        lib.optionalString (vars != { }) (lib.toShellVars vars + "\n")
        + lib.concatMapStrings (part: if lib.isPath part then builtins.readFile part else part) parts;
    };
}
