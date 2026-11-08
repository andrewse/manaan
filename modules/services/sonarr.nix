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
    machine.autostart.sonarr = lib.mkDefault false;

    services.sonarr.group = "media";
    users.groups.media = { };

    machine.firewall.internalTCPPorts = [ port ];
    # Its libraries and downloads are the host's to add.
    machine.sandbox.sonarr.writes = [ cfg.dataDir ];
    # systemd won't start a unit whose ReadWritePaths= is missing, and nixpkgs
    # leaves Sonarr to make its data dir on its first start: make it first, as
    # nixpkgs does for Radarr's.
    systemd.tmpfiles.settings."10-sonarr".${cfg.dataDir}.d = {
      inherit (cfg) user group;
      mode = "0700";
    };

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

    machine.serviceCommands.sonarr.unit = "sonarr.service";
  };
}
