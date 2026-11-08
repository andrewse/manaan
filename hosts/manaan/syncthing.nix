# Syncthing on manaan: the old Ubuntu manaan's config dir layout and user and
# group IDs, but not its device identity. Syncthing makes its own keys in the
# config dir on first start, so paired devices have to pair with the new device
# ID. The rest is in modules/services/syncthing.nix.
{ config, lib, ... }:

let
  cfg = config.services.syncthing;
in
{
  # Config and index database together, as in /etc/opt/syncthing on the old host.
  services.syncthing.configDir = "/var/lib/syncthing";

  # Every folder in its config.xml is on endor's syncthing share.
  machine.sandbox = lib.mkIf cfg.enable { syncthing.writes = [ "/mnt/endor/syncthing" ]; };

  # The same IDs as on the old host, so files it wrote to the NFS shares
  # (which go by numeric ID) still belong to it.
  users = lib.mkIf cfg.enable {
    users.syncthing = {
      uid = lib.mkForce 3001;
      # Implied by the module's own UID, which is in the system range; 3001 isn't.
      isSystemUser = true;
    };
    groups.syncthing.gid = lib.mkForce 989;
  };
}
