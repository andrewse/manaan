# Gatus: a status page polling machine.healthchecks each minute, with history,
# and alerts through ntfy once the ntfy secret exists: every service with a
# health URL, and every enabled tcp and http check. unit and command checks
# aren't something Gatus can poll. It runs on the machine it watches, so it
# can't report that machine being down.
{ config, lib, ... }:

let
  cfg = config.services.gatus;
  health = config.machine.healthchecks;
  ntfy = config.machine.notify.environmentFile;
  port = 8090;
  alerts = lib.optional (ntfy != null) { type = "ntfy"; };
  # A service that isn't started at boot would only ever be alerted on.
  started = lib.filterAttrs (unit: _: config.machine.autostart.${unit} or true) health.services;
  # Checks are already off when what they check doesn't start at boot.
  polled = lib.filterAttrs (
    _: check: check.enable && (check.type == "tcp" || check.type == "http")
  ) health.checks;

  # As healthcheck.sh probes them: a tcp check must accept a connection; an
  # http check must answer 2xx/3xx, a redirect counting without following it.
  fromService = service: { inherit (service) url conditions; };
  fromCheck =
    check:
    if check.type == "tcp" then
      {
        url = "tcp://${check.target}";
        conditions = [ "[CONNECTED] == true" ];
      }
    else
      {
        url = check.target;
        conditions = [
          "[STATUS] >= 200"
          "[STATUS] < 400"
        ];
        client.ignore-redirect = true;
      };
  # Named by service unit or check name, which Gatus needs unique in a group.
  # They can't clash: each service already has a unit check under its name
  # (../healthchecks/services.nix), so no tcp or http check can take it.
  watched =
    lib.mapAttrs (_: fromService) (removeAttrs started [ "gatus" ])
    // lib.mapAttrs (_: fromCheck) polled;
in
{
  config = lib.mkIf cfg.enable {
    machine.autostart.gatus = lib.mkDefault false;

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
        endpoints = lib.mapAttrsToList (
          name: endpoint:
          endpoint
          // {
            inherit name alerts;
            group = config.networking.hostName;
            interval = "1m";
          }
        ) watched;
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
    # A user of its own each start (DynamicUser); its database is in its
    # StateDirectory, so it writes nothing else.
    machine.sandbox.gatus = { };

    machine.serviceCommands.gatus.unit = "gatus.service";
  };
}
