# Integration tests: several scripts or modules together, still with nothing
# outside the build sandbox -- no VM, no network, no clock to wait on -- so they
# take seconds too.
#
#   integration-rollback      self-upgrade's scripts across reboots, against a
#                             fake firmware
#   integration-git-server    git pushing and cloning through the wrapper
#   integration-<host>        the host's whole config, as it ships (host/)
{ pkgs, hosts }:

let
  inherit (pkgs) lib;
  scriptTest =
    name: test: args:
    import ../script-test.nix { inherit pkgs; } "integration-${name}" test args;
in
lib.mapAttrs' (
  name: host:
  lib.nameValuePair "integration-${name}" (
    import ../nix-harness.nix { inherit pkgs; } "integration-${name}" (
      import ./host {
        inherit lib name;
        inherit (host) config;
      }
    )
  )
) hosts
// {
  integration-rollback = scriptTest "rollback" ./rollback.test.sh [ "${../../modules/self-upgrade}" ];
  integration-git-server = scriptTest "git-server" ./git-server.test.sh [
    "${../../modules/services/git-server}"
  ];
}
