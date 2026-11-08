# Integration tests: several scripts or modules together, still with nothing
# outside the build sandbox -- no VM, no network, no clock to wait on -- so they
# take seconds too.
#
#   integration-rollback      self-upgrade's scripts across reboots, against a
#                             fake firmware
#   integration-git-server    git pushing and cloning through the wrapper
#   integration-<host>        the host's whole config, as it ships (host/)
#   integration-<host>-all-services-off, -on
#                             the same, with every service switched off, or
#                             every one on (all-services.nix)
{ pkgs, hosts }:

let
  inherit (pkgs) lib;
  scriptTest =
    name: test: args:
    import ../script-test.nix { inherit pkgs; } "integration-${name}" test args;
  hostTest =
    check: name: config: cases:
    import ../nix-harness.nix { inherit pkgs; } "integration-${check}" (
      import ./host { inherit lib name config; } // cases
    );
  allServices = import ./all-services.nix { inherit lib; };
  states = {
    off = false;
    on = true;
  };
  allServicesTest =
    name: host: state: enable:
    let
      check = "${name}-all-services-${state}";
      inherit (host.extendModules { modules = [ (allServices.module enable) ]; }) config;
    in
    lib.nameValuePair "integration-${check}" (
      hostTest check name config (allServices.cases enable config)
    );
in
lib.concatMapAttrs (
  name: host:
  {
    "integration-${name}" = hostTest name name host.config { };
  }
  // lib.mapAttrs' (allServicesTest name host) states
) hosts
// {
  integration-rollback = scriptTest "rollback" ./rollback.test.sh [ "${../../modules/self-upgrade}" ];
  integration-git-server = scriptTest "git-server" ./git-server.test.sh [
    "${../../modules/services/git-server}"
  ];
}
