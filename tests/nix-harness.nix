# Shared by the Nix tests. Each case is an expression and the value it should
# have, named for the behaviour it shows:
#   "a unit check per service" = { expr = ...; expected = ...; };
# The cases are decided when the check is evaluated, and the check only prints
# the result, one line per case as the script tests do, failing if any case
# did. So it builds in a moment, and needs nothing the cases name built: their
# store paths are only text in the report.
{ pkgs }:

name: cases:
let
  inherit (pkgs) lib;
  show = lib.generators.toPretty { };
  lines = lib.mapAttrsToList (
    description: case:
    if case.expr == case.expected then
      "ok: ${description}"
    else
      lib.concatLines [
        "not ok: ${description}"
        "  got:      ${show case.expr}"
        "  expected: ${show case.expected}"
      ]
  ) cases;
  failures = lib.count (lib.hasPrefix "not ok") lines;
in
pkgs.runCommand name
  {
    report = builtins.unsafeDiscardStringContext (lib.concatLines lines);
    passAsFile = [ "report" ];
  }
  ''
    cat "$reportPath"
    ${lib.optionalString (failures > 0) ''
      echo "${toString failures} failed"
      exit 1
    ''}
    touch $out
  ''
