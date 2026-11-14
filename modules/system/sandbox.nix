# What each service may write, declared once by the module that runs it:
#   machine.sandbox.sonarr.writes = [ config.services.sonarr.dataDir ];
# The unit sees the rest of the file system read-only (ProtectSystem=strict)
# and no home directories, so a compromised service can damage only what it
# was given. That leaves the host's /tmp read-only too, so each also gets a
# /tmp of its own (PrivateTmp), which goes when it stops. Each also runs as its own user, never root, unless it says why
# it can't.
{ config, lib, ... }:

let
  cfg = config.machine.sandbox;
in
{
  options.machine.sandbox = lib.mkOption {
    default = { };
    description = "Services, by systemd unit name, and the only paths each may write.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          writes = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = ''
              Paths the unit may write. Its StateDirectory= and RuntimeDirectory=
              are writable anyway. A path starting with `-` is skipped if it
              doesn't exist, as for one only some hosts have.
            '';
          };
          root = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "The unit runs as root. Say why beside it.";
          };
        };
      }
    );
  };

  config = {
    systemd.services = lib.mapAttrs (_: unit: {
      serviceConfig = {
        ProtectSystem = lib.mkForce "strict";
        ProtectHome = lib.mkDefault true;
        PrivateTmp = lib.mkDefault true;
        ReadWritePaths = unit.writes;
      };
    }) cfg;

    assertions = lib.mapAttrsToList (
      name: unit:
      let
        user = config.systemd.services.${name}.serviceConfig.User or "root";
      in
      {
        assertion = unit.root || user != "root";
        message = "${name}.service runs as root: give it its own user, or set machine.sandbox.${name}.root and say why.";
      }
    ) cfg;
  };
}
