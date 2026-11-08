# Which services start at boot, by systemd unit name. Each module in
# services/ sets its own unit to `lib.mkDefault false`, so a service switched
# on is installed and configured but only starts at boot once the host says
#   machine.autostart.sonarr = true;
# Until then `systemctl start sonarr` runs it until the next boot, and its
# healthchecks are dropped, so a service not yet trusted can't fail the boot
# healthchecks and roll back an upgrade. A unit no module lists (sshd, the
# healthchecks, self-upgrade) always starts.
#
# Modules whose service has companion units (an init unit, a timer) switch
# those off too, by reading this. A service with no unit of its own (the git
# server) lists its name in machine.autostartUnitless, and only its own module
# acts on it.
{ config, lib, ... }:

let
  cfg = config.machine.autostart;
in
{
  options.machine.autostart = lib.mkOption {
    type = with lib.types; attrsOf bool;
    default = { };
    description = "Whether each systemd service, by unit name without .service, starts at boot; one not listed does.";
  };

  options.machine.autostartUnitless = lib.mkOption {
    type = with lib.types; listOf str;
    default = [ ];
    internal = true;
    description = "Names in machine.autostart that aren't systemd units, so get no unit of that name.";
  };

  config.systemd.services = lib.mapAttrs (_: _: { wantedBy = lib.mkForce [ ]; }) (
    lib.filterAttrs (name: start: !start && !lib.elem name config.machine.autostartUnitless) cfg
  );
}
