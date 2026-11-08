# Grafana over Prometheus (../prometheus.nix): the way in to the metrics, with
# the machine's dashboard (dashboard/) provisioned. Edits made to it in the web
# UI are lost at the next restart.
#
# The admin password is generated on first start, into
# /var/lib/grafana/admin-password. It only sets the password of a new database:
# once changed in the web UI, the file is stale.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.grafana;
  prometheus = config.services.prometheus;
  port = 3000;

  secretKey = "${cfg.dataDir}/secret-key";
  adminPassword = "${cfg.dataDir}/admin-password";

  # The units the healthchecks require, shown up or down on the dashboard.
  units = lib.sort lib.lessThan (
    lib.mapAttrsToList (_: check: check.target) (
      lib.filterAttrs (_: check: check.enable && check.type == "unit") config.machine.healthchecks.checks
    )
  );

  dashboards = pkgs.writeTextDir "${config.networking.hostName}.json" (
    builtins.toJSON (
      import ./dashboard {
        inherit lib units;
        title = config.networking.hostName;
        docker = config.virtualisation.docker.enable;
      }
    )
  );
in
{
  config = lib.mkIf cfg.enable {
    machine.autostart.grafana = lib.mkDefault false;

    assertions = [
      {
        assertion = prometheus.enable;
        message = "Grafana shows Prometheus's metrics: enable services.prometheus too.";
      }
    ];

    services.grafana = {
      settings = {
        server = {
          http_addr = "0.0.0.0";
          http_port = port;
          domain = config.networking.hostName;
        };
        security = {
          secret_key = "$__file{${secretKey}}";
          admin_password = "$__file{${adminPassword}}";
        };
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          check_for_plugin_updates = false;
        };
      };
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            uid = "prometheus";
            type = "prometheus";
            url = "http://127.0.0.1:${toString prometheus.port}";
            isDefault = true;
            jsonData.timeInterval = prometheus.globalConfig.scrape_interval;
          }
        ];
        dashboards.settings.providers = [
          {
            name = "machine";
            # Edits in the web UI are lost at the next restart; change dashboard/.
            allowUiUpdates = false;
            options.path = dashboards;
          }
        ];
      };
    };

    # Both are made once and kept, so sessions and the admin login survive restarts.
    systemd.services.grafana.preStart = lib.mkBefore ''
      for f in ${secretKey} ${adminPassword}; do
        [ -s "$f" ] || (umask 077 && head -c 24 /dev/urandom | base64 | tr -d '\n' > "$f")
      done
    '';

    machine.firewall.internalTCPPorts = [ port ];
    machine.sandbox.grafana.writes = [ cfg.dataDir ];

    machine.healthchecks.checks = {
      grafana = {
        type = "unit";
        target = "grafana.service";
      };
      grafana-http = {
        enable = config.machine.autostart.grafana;
        type = "http";
        target = "http://127.0.0.1:${toString port}/api/health";
      };
    };

    machine.serviceCommands.grafana = {
      unit = "grafana.service";
      # The module puts Grafana's own `grafana` on PATH.
      passthrough = lib.getExe' cfg.package "grafana";
    };
  };
}
