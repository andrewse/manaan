# Sonarr: picks series releases for SABnzbd to download. It is configured in its
# web UI; that state lives under /var/lib. It runs in the `media` group, as do
# Radarr and SABnzbd, so they can share the libraries they write.
{ config, lib, ... }:

let
  cfg = config.services.sonarr;
  port = 8989;
in
{
  config = lib.mkIf cfg.enable {
    services.sonarr.group = "media";
    users.groups.media = { };

    machine.firewall.internalTCPPorts = [ port ];

    # Its own health endpoint, which needs no API key. It migrates its database
    # on the first start after an upgrade: give it longer to come up.
    machine.healthchecks.services.sonarr = {
      url = "http://127.0.0.1:${toString port}/ping";
      conditions = [
        "[STATUS] == 200"
        "[BODY].status == OK"
      ];
      startTimeout = 900;
    };
  };
}
