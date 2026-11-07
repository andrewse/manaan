# Syncthing, keeping the device identity of the old Ubuntu manaan so paired
# devices carry on syncing with it. Folders and devices are managed in the web
# UI, as before, and live in config.xml in the config dir, not here.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.syncthing;
  guiPort = 8384;

  # The device certificate and the web UI's HTTPS certificate. The certificates
  # are public; their keys are secrets (`make secret NAME=syncthing-key` and
  # `NAME=syncthing-https-key`, from key.pem and https-key.pem).
  key = ../../secrets/syncthing-key.age;
  httpsKey = ../../secrets/syncthing-https-key.age;
  useKeys = config.machine.secrets.enable && builtins.pathExists key && builtins.pathExists httpsKey;
in
{
  services.syncthing = {
    enable = true;
    # Config and index database together, as in /etc/opt/syncthing on the old host.
    configDir = "/var/lib/syncthing";
    guiAddress = "0.0.0.0:${toString guiPort}";
    openDefaultPorts = true;
    overrideDevices = false;
    overrideFolders = false;
    cert = lib.mkIf useKeys "${./syncthing/cert.pem}";
    key = lib.mkIf useKeys config.age.secrets.syncthing-key.path;
  };

  age.secrets = lib.mkIf useKeys {
    syncthing-key.file = key;
    syncthing-https-key.file = httpsKey;
  };

  # The module copies in cert.pem and key.pem; the web UI's pair goes in alongside.
  systemd.services.syncthing.serviceConfig.ExecStartPre = lib.mkIf useKeys (
    lib.mkAfter [
      "+${pkgs.writers.writeBash "syncthing-copy-https-keys" ''
        install -Dm644 -o ${cfg.user} -g ${cfg.group} ${./syncthing/https-cert.pem} ${cfg.configDir}/https-cert.pem
        install -Dm600 -o ${cfg.user} -g ${cfg.group} ${config.age.secrets.syncthing-https-key.path} ${cfg.configDir}/https-key.pem
      ''}"
    ]
  );

  # The same IDs as on the old host, so files it wrote to the NFS shares
  # (which go by numeric ID) still belong to it.
  users.users.syncthing = {
    uid = lib.mkForce 3001;
    # Implied by the module's own UID, which is in the system range; 3001 isn't.
    isSystemUser = true;
  };
  users.groups.syncthing.gid = lib.mkForce 989;

  machine.firewall.internalTCPPorts = [ guiPort ];

  machine.smokeTests.checks = {
    syncthing = {
      type = "unit";
      target = "syncthing.service";
    };
    syncthing-gui = {
      type = "tcp";
      target = "127.0.0.1:${toString guiPort}";
    };
  };
}
