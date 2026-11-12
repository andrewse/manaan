# Syncthing. Folders and devices are managed in the web UI and live in
# config.xml in its config dir, not here. Its GUI gets a login
# the first time it has none (modules/admin-login/).
{ config, lib, ... }:

let
  cfg = config.services.syncthing;
  guiPort = 8384;
  autostart = config.machine.autostart.syncthing;
in
{
  config = lib.mkIf cfg.enable {
    machine.autostart.syncthing = lib.mkDefault false;

    services.syncthing = {
      guiAddress = "0.0.0.0:${toString guiPort}";
      openDefaultPorts = true;
      overrideDevices = false;
      overrideFolders = false;
    };

    # Applies the settings above, and would start Syncthing: it runs once
    # Syncthing is started. guiAddress means the unit is always there.
    systemd.services.syncthing-init = lib.mkIf (!autostart) {
      wantedBy = lib.mkForce [ "syncthing.service" ];
    };

    machine.firewall.internalTCPPorts = [ guiPort ];
    # The folders it syncs elsewhere are the host's to add.
    machine.sandbox.syncthing.writes = lib.unique [
      cfg.configDir
      cfg.databaseDir
      cfg.dataDir
    ];

    machine.healthchecks.services.syncthing = {
      url = "http://127.0.0.1:${toString guiPort}/rest/noauth/health";
      conditions = [
        "[STATUS] == 200"
        "[BODY].status == OK"
      ];
    };

    machine.serviceCommands.syncthing = {
      unit = "syncthing.service";
      # The module puts Syncthing's own `syncthing` on PATH.
      passthrough = lib.getExe' cfg.package "syncthing";
    };
  };
}
