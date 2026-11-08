# SABnzbd: downloads the releases Sonarr and Radarr pick, in the `media` group
# they share. Servers, categories and logins are set in its web UI; that state
# lives under /var/lib.
{ config, lib, ... }:

let
  cfg = config.services.sabnzbd;
  port = 8080;
in
{
  config = lib.mkIf cfg.enable {
    machine.autostart.sabnzbd = lib.mkDefault false;

    services.sabnzbd = {
      group = "media";
      # The settings here are merged over sabnzbd.ini at each start.
      allowConfigWrite = true;
      settings.misc = {
        host = "0.0.0.0";
        inherit port;
        inet_exposure = "api+web (auth needed)";
      };
    };
    users.groups.media = { };

    # It unpacks RAR archives with unrar, which is unfree. The binary cache
    # doesn't carry it, so it is built from source; it's small.
    nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "unrar";

    machine.firewall.internalTCPPorts = [ port ];
    # Its downloads are the host's to add.
    machine.sandbox.sabnzbd.writes = [ "/var/lib/${cfg.stateDir}" ];
    # The sandbox leaves /tmp read-only, and nixpkgs' preStart builds the
    # merged sabnzbd.ini in a file from a bare mktemp, so it gets a /tmp of
    # its own to write.
    systemd.services.sabnzbd.serviceConfig.PrivateTmp = true;

    # Its own health endpoint, which needs no API key.
    machine.healthchecks.services.sabnzbd.url =
      "http://127.0.0.1:${toString port}/api?mode=version&output=json";

    machine.serviceCommands.sabnzbd.unit = "sabnzbd.service";
  };
}
