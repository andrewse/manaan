# NZBHydra2: searches Usenet indexers for Sonarr and Radarr. It is configured
# in its web UI; that state lives under /var/lib.
{ config, lib, ... }:

let
  cfg = config.services.nzbhydra2;
  port = 5076;
in
{
  config = lib.mkIf cfg.enable {
    machine.firewall.internalTCPPorts = [ port ];
    machine.sandbox.nzbhydra2.writes = [ cfg.dataDir ];

    # Its own health endpoint, which needs no API key. It is a JVM: give it
    # longer to come up.
    machine.healthchecks.services.nzbhydra2 = {
      url = "http://127.0.0.1:${toString port}/actuator/health/ping";
      startTimeout = 900;
    };
  };
}
