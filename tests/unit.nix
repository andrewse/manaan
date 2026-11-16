# Unit tests: one script or one module on its own, one case per behaviour. No
# VM, so they take seconds.
#
# A script's tests are beside it, as <name>.test.sh, and run it against stubbed
# commands; they share script-harness.sh, which they source from PATH (see
# script-test.nix).
#
# A module's tests are beside it too, as <name>.test.nix: cases (see
# nix-harness.nix) on the config it makes when it is evaluated with no other
# module of this repo's, given `evalModules`, which takes a list of modules and
# returns their NixOS config.
{ pkgs, evalModules }:

let
  inherit (pkgs) lib;
  scriptTestWith =
    name: dir: file: args:
    import ./script-test.nix { inherit pkgs; } "unit-${name}" "${dir}/${file}" args;
  scriptTest =
    name: dir: file:
    scriptTestWith name dir file [ ];
  moduleTest =
    name: file:
    import ./nix-harness.nix { inherit pkgs; } "unit-${name}" (
      import file { inherit lib evalModules; }
    );
in
{
  unit-upgrade = scriptTest "upgrade" ../modules/self-upgrade "upgrade.test.sh";
  unit-verify = scriptTest "verify" ../modules/self-upgrade "verify.test.sh";
  unit-deadline = scriptTest "deadline" ../modules/self-upgrade "deadline.test.sh";
  unit-install = scriptTest "install" ../installer "install.test.sh";
  unit-healthcheck = scriptTest "healthcheck" ../modules/healthchecks "healthcheck.test.sh";
  unit-service-command =
    scriptTest "service-command" ../modules/service-commands
      "service-command.test.sh";
  unit-git-server = scriptTest "git-server" ../modules/services/git-server "wrapper.test.sh";
  # The real tools the scripts use, and the base config NZBHydra2 starts from.
  unit-admin-login-scripts =
    scriptTestWith "admin-login-scripts" ../modules/admin-login "admin-login.test.sh"
      [
        (lib.makeBinPath [
          pkgs.jq
          pkgs.yq-go
          pkgs.mkpasswd
        ])
        "${pkgs.nzbhydra2.src}/core/src/main/resources/config/baseConfig.yml"
      ];

  unit-firewall = moduleTest "firewall" ../modules/system/firewall.test.nix;
  unit-sandbox = moduleTest "sandbox" ../modules/system/sandbox.test.nix;
  unit-healthchecks = moduleTest "healthchecks" ../modules/healthchecks/healthchecks.test.nix;
  unit-service-commands = moduleTest "service-commands" ../modules/service-commands/service-commands.test.nix;
  unit-self-upgrade = moduleTest "self-upgrade" ../modules/self-upgrade/self-upgrade.test.nix;
  unit-admin-login = moduleTest "admin-login" ../modules/admin-login/admin-login.test.nix;
  unit-self-upgrade-watchdog = moduleTest "self-upgrade-watchdog" ../modules/self-upgrade/watchdog.test.nix;
  unit-installer = moduleTest "installer" ../installer/installer.test.nix;
}
