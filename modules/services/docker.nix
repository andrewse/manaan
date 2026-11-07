# Docker for compose projects run by hand. Containers and their volumes are not
# part of the system: rolling back an upgrade doesn't touch them.
#
# Published ports go through Docker's own firewall rules, not the host's, so a
# published port is reachable from anywhere that can reach the host.
{
  config,
  lib,
  ...
}:

let
  cfg = config.machine.docker;
in
{
  options.machine.docker.enable = lib.mkEnableOption "Docker";

  config = lib.mkIf cfg.enable {
    virtualisation.docker = {
      enable = true;
      # Container logs stay with the container, rotated, rather than in the journal.
      logDriver = "json-file";
      daemon.settings.log-opts = {
        max-size = "10m";
        max-file = "3";
      };
      # Stopped containers, unused networks, the build cache, and images no
      # container has used for a week. Named volumes are never pruned.
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [
          "--all"
          "--filter"
          "until=168h"
        ];
      };
    };

    # The docker group is root in all but name; admins have passwordless sudo anyway.
    users.users = lib.mapAttrs (_: _: { extraGroups = [ "docker" ]; }) config.machine.users;

    machine.healthchecks.checks.docker = {
      type = "command";
      target = "${lib.getExe config.virtualisation.docker.package} info";
    };
  };
}
