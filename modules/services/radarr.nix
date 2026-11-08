# Radarr: picks movie releases for SABnzbd to download. It is configured in its
# web UI; that state lives under /var/lib. It runs in the `media` group, as do
# Sonarr and SABnzbd, so they can share the libraries they write.
{ config, lib, ... }:

let
  cfg = config.services.radarr;
  port = 7878;
in
{
  config = lib.mkIf cfg.enable {
    services.radarr.group = "media";
    users.groups.media = { };

    machine.firewall.internalTCPPorts = [ port ];
    # Its libraries and downloads are the host's to add.
    machine.sandbox.radarr.writes = [ cfg.dataDir ];

    # Its own health endpoint, which needs no API key. It migrates its database
    # on the first start after an upgrade: give it longer to come up.
    machine.healthchecks.services.radarr = {
      url = "http://127.0.0.1:${toString port}/ping";
      conditions = [
        "[STATUS] == 200"
        "[BODY].status == OK"
      ];
      startTimeout = 900;
    };

    machine.serviceCommands.radarr.unit = "radarr.service";
  };
}
