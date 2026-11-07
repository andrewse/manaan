# Syncthing. Folders and devices are managed in the web UI and live in
# config.xml in its config dir, not here.
{ config, lib, ... }:

let
  cfg = config.services.syncthing;
  guiPort = 8384;
in
{
  config = lib.mkIf cfg.enable {
    services.syncthing = {
      guiAddress = "0.0.0.0:${toString guiPort}";
      openDefaultPorts = true;
      overrideDevices = false;
      overrideFolders = false;
    };

    machine.firewall.internalTCPPorts = [ guiPort ];

    machine.healthchecks.services.syncthing = {
      url = "http://127.0.0.1:${toString guiPort}/rest/noauth/health";
      conditions = [
        "[STATUS] == 200"
        "[BODY].status == OK"
      ];
    };
  };
}
