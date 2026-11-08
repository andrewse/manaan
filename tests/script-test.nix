# A script test as a check: shellchecked, then run with script-harness.sh on
# PATH and the arguments it is given. `test` is a path into the store, inside
# the directory it was copied with, so the scripts beside it are there too.
{ pkgs }:

let
  inherit (pkgs) lib;
  harness = lib.fileset.toSource {
    root = ./.;
    fileset = ./script-harness.sh;
  };
in
name: test: args:
pkgs.runCommand name
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.shellcheck
    ];
  }
  ''
    shellcheck -x -P ${harness} ${harness}/script-harness.sh ${test}
    PATH=${harness}:$PATH bash ${test} ${lib.escapeShellArgs args}
    touch $out
  ''
