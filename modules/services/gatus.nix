# Gatus: a status page polling every service in machine.healthchecks each minute,
# with history, and alerts through ntfy once the ntfy secret exists. It runs on
# the machine it watches, so it can't report that machine being down.
{ config, lib, ... }:

let
  cfg = config.services.gatus;
  health = config.machine.healthchecks;
  ntfy = config.machine.notify.environmentFile;
  port = 8090;
  alerts = lib.optional (ntfy != null) { type = "ntfy"; };
in
{
  config = lib.mkIf cfg.enable {
    services.gatus = {
      environmentFile = ntfy;
      settings = {
        web.port = port;
        storage = {
          type = "sqlite";
          path = "/var/lib/gatus/data.db";
        };
        # Gatus fills in ${...} from its environment, here the ntfy secret.
        alerting = lib.mkIf (alerts != [ ]) {
          ntfy = {
            url = "\${NTFY_URL}";
            topic = "\${NTFY_TOPIC}";
            default-alert = {
              failure-threshold = 3;
              success-threshold = 2;
              send-on-resolved = true;
            };
          };
        };
        endpoints = lib.mapAttrsToList (name: service: {
          inherit name alerts;
          inherit (service) url conditions;
          group = config.networking.hostName;
          interval = "1m";
        }) (removeAttrs health.services [ "gatus" ]);
      };
    };

    machine.healthchecks.services.gatus = {
      url = "http://127.0.0.1:${toString port}/health";
      conditions = [
        "[STATUS] == 200"
        "[BODY].status == UP"
      ];
    };

    machine.firewall.internalTCPPorts = [ port ];
  };
}
