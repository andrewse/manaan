# Syncthing as it was on the old Ubuntu manaan: the same device identity, so
# paired devices carry on syncing with it, the same config dir layout, and the
# same user and group IDs. The rest is in modules/services/syncthing.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.syncthing;

  # The device certificate and the web UI's HTTPS certificate. The certificates
  # are public; their keys are secrets (`make secret NAME=syncthing-key` and
  # `NAME=syncthing-https-key`, from key.pem and https-key.pem).
  secrets = config.machine.secrets.paths;
  useKeys = secrets ? syncthing-key && secrets ? syncthing-https-key;
in
{
  services.syncthing = {
    # Config and index database together, as in /etc/opt/syncthing on the old host.
    configDir = "/var/lib/syncthing";
    cert = lib.mkIf useKeys "${./syncthing/cert.pem}";
    key = lib.mkIf useKeys secrets.syncthing-key;
  };

  # Every folder in its config.xml is on endor's syncthing share.
  machine.sandbox = lib.mkIf cfg.enable { syncthing.writes = [ "/mnt/endor/syncthing" ]; };

  machine.secrets.use = [
    "syncthing-key"
    "syncthing-https-key"
  ];

  # The module copies in cert.pem and key.pem; the web UI's pair goes in alongside.
  systemd.services.syncthing.serviceConfig.ExecStartPre = lib.mkIf (cfg.enable && useKeys) (
    lib.mkAfter [
      "+${pkgs.writers.writeBash "syncthing-copy-https-keys" ''
        install -Dm644 -o ${cfg.user} -g ${cfg.group} ${./syncthing/https-cert.pem} ${cfg.configDir}/https-cert.pem
        install -Dm600 -o ${cfg.user} -g ${cfg.group} ${secrets.syncthing-https-key} ${cfg.configDir}/https-key.pem
      ''}"
    ]
  );

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
