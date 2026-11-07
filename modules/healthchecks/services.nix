# The health of each long-running service, declared once by the module that runs it:
#   machine.healthchecks.services.sonarr.url = "http://127.0.0.1:8989/ping";
# systemd holds the unit in `activating` until the URL answers, so the unit's
# state is the service's health:
#   activating = starting, active = healthy, failed = unhealthy
# (it didn't answer within startTimeout). Each becomes a `unit` healthcheck
# that reads that state, Gatus (../monitoring/gatus.nix) keeps polling the URL while the
# machine runs, and a unit that fails sends a notification once the ntfy
# secret exists.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.machine.healthchecks;
  ntfy = config.machine.secrets.paths.ntfy or null;
  useNtfy = ntfy != null;

  # Any answer short of a server error counts: a login page or a 401 still
  # shows the service is up, and a later auth setting mustn't fail an upgrade.
  # Gatus checks the answer itself.
  waitHealthy = pkgs.writeShellApplication {
    name = "wait-healthy";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      until
        code=$(curl --silent --output /dev/null --max-time 5 --write-out '%{http_code}' "$1" || true)
        ((code >= 200 && code < 500))
      do
        sleep 2
      done
    '';
  };

  notifyFailure = pkgs.writeShellApplication {
    name = "notify-failure";
    runtimeInputs = [
      pkgs.curl
      config.systemd.package
    ];
    text = ''
      unit=$1
      systemctl status --no-pager --lines=10 "$unit" |
        curl --silent --show-error --max-time 10 \
          --header "Title: ${config.networking.hostName}: $unit failed" \
          --header "Tags: warning" \
          --data-binary @- "$NTFY_URL/$NTFY_TOPIC"
    '';
  };
in
{
  options.machine.healthchecks = {
    services = lib.mkOption {
      default = { };
      description = "Long-running services, by systemd unit name, and how to tell each is healthy.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "Answers once the service is up; ideally its own health endpoint.";
            };
            conditions = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ "[STATUS] == 200" ];
              description = "What Gatus requires of the answer, in Gatus's condition syntax.";
            };
            startTimeout = lib.mkOption {
              type = lib.types.ints.positive;
              default = 300;
              description = "Seconds the service may take to answer after it starts before it counts as failed.";
            };
          };
        }
      );
    };
    ntfyEnvironmentFile = lib.mkOption {
      type = with lib.types; nullOr str;
      readOnly = true;
      default = ntfy;
      description = "NTFY_URL and NTFY_TOPIC, once the ntfy secret exists.";
    };
  };

  config = {
    systemd.services =
      lib.mapAttrs (_: service: {
        serviceConfig = {
          ExecStartPost = [
            (utils.escapeSystemdExecArgs [
              (lib.getExe waitHealthy)
              service.url
            ])
          ];
          TimeoutStartSec = service.startTimeout;
        };
        onFailure = lib.optional useNtfy "notify-failure@%n.service";
      }) cfg.services
      // {
        healthcheck.onFailure = lib.optional useNtfy "notify-failure@%n.service";
        "notify-failure@" = lib.mkIf useNtfy {
          description = "Notify that %i failed";
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = ntfy;
            ExecStart = "${lib.getExe notifyFailure} %i";
          };
        };
      };

    # `make secret NAME=ntfy`: NTFY_URL=https://ntfy.sh and NTFY_TOPIC=<topic> lines.
    machine.secrets.use = [ "ntfy" ];

    machine.healthchecks.checks = lib.mapAttrs (name: service: {
      type = "unit";
      target = "${name}.service";
      # Counted from when the healthchecks start, a little before the service may.
      timeout = service.startTimeout + 60;
    }) cfg.services;
  };
}
