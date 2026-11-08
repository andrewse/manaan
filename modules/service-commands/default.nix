# A command per service for looking after it from a shell, declared by the
# module that runs it, e.g.
#   machine.serviceCommands.sonarr.unit = "sonarr.service";
# puts `sonarr` on PATH: `sonarr logs`, `sonarr restart` and so on, wrapping
# journalctl and systemctl. A service with no unit of its own (the git server)
# sets only `journal`, and gets the journal commands alone.
#
# The name is the command, and the command wins PATH over any package's
# program of the same name. Where the service's own package has one (Syncthing,
# Grafana), `passthrough` names it, and anything but these commands goes to it.
# Otherwise the build fails on a clash rather than hide the program, which is
# why there is no `docker`, `tailscale` or `sshd` command.
{
  config,
  lib,
  pkgs,
  machineLib,
  ...
}:

let
  cfg = config.machine.serviceCommands;

  command =
    name: service:
    machineLib.mkScript {
      inherit name;
      runtimeInputs = [ config.systemd.package ];
      vars = {
        inherit name;
        unit = toString service.unit;
        inherit (service) journal;
        passthrough = toString service.passthrough;
      };
      parts = [ ./service-command.sh ];
    };
  commands = lib.mapAttrs command cfg;

  # Every other package's program of the same name, for a command with no
  # passthrough to hand it on to.
  clashes = pkgs.runCommand "service-command-clashes" { } ''
    ${lib.concatStrings (
      lib.mapAttrsToList (name: script: ''
        for pkg in ${toString config.environment.systemPackages}; do
          if [[ $pkg != ${script} && -e $pkg/bin/${name} ]]; then
            echo "machine.serviceCommands.${name} would hide $pkg/bin/${name}: rename it, or set its passthrough" >&2
            exit 1
          fi
        done
      '') (lib.filterAttrs (name: _: cfg.${name}.passthrough == null) commands)
    )}
    touch $out
  '';
in
{
  options.machine.serviceCommands = lib.mkOption {
    default = { };
    description = "Services, by the name of the command that looks after each.";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options = {
            unit = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              description = "The systemd unit status, start, stop and restart act on; null for none.";
            };
            journal = lib.mkOption {
              type = with lib.types; listOf str;
              default = lib.optional (config.unit != null) "--unit=${config.unit}";
              defaultText = lib.literalExpression ''[ "--unit=''${unit}" ]'';
              description = "journalctl options selecting the service's entries.";
            };
            passthrough = lib.mkOption {
              type = with lib.types; nullOr path;
              default = null;
              example = lib.literalExpression ''lib.getExe' pkgs.syncthing "syncthing"'';
              description = "The program of the same name the command hides, given anything but its own commands.";
            };
          };
        }
      )
    );
  };

  config = {
    assertions = lib.mapAttrsToList (name: service: {
      assertion = service.journal != [ ];
      message = "machine.serviceCommands.${name} needs a unit or journal options to read its logs by.";
    }) cfg;

    environment.systemPackages = map lib.hiPrio (lib.attrValues commands);
    system.checks = lib.optional (cfg != { }) clashes;
  };
}
