# Prometheus, keeping the machine's own metrics: it scrapes itself and the
# exporters that are on (node-exporter.nix, cadvisor.nix). It listens on
# localhost only; Grafana (grafana/) is the way in.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.prometheus;
  local = port: "127.0.0.1:${toString port}";
  autostart = unit: config.machine.autostart.${unit} or true;
  # An exporter that isn't started at boot isn't scraped: its target would be
  # down, and fail prometheus-targets.
  jobs = lib.filter (job: job.enable) [
    {
      name = "node";
      enable = cfg.exporters.node.enable && autostart "prometheus-node-exporter";
      inherit (cfg.exporters.node) port;
    }
    {
      name = "cadvisor";
      enable = config.services.cadvisor.enable && autostart "cadvisor";
      inherit (config.services.cadvisor) port;
    }
    {
      name = "prometheus";
      enable = true;
      inherit (cfg) port;
    }
  ];
in
{
  config = lib.mkIf cfg.enable {
    machine.autostart.prometheus = lib.mkDefault false;

    services.prometheus = {
      listenAddress = "127.0.0.1";
      port = 9090;
      # On manaan its data has a 20G volume of its own; whichever limit comes first.
      retentionTime = "90d";
      extraFlags = [ "--storage.tsdb.retention.size=16GB" ];
      globalConfig.scrape_interval = "15s";
      scrapeConfigs = map (job: {
        job_name = job.name;
        static_configs = [ { targets = [ (local job.port) ]; } ];
      }) jobs;
    };

    machine.sandbox.prometheus.writes = [ "/var/lib/${cfg.stateDir}" ];

    machine.healthchecks.checks = {
      prometheus = {
        type = "unit";
        target = "prometheus.service";
      };
      prometheus-targets = {
        enable = autostart "prometheus";
        type = "command";
        target = "${lib.getExe pkgs.curl} -sf http://${local cfg.port}/api/v1/targets | ${lib.getExe pkgs.jq} -e '.data.activeTargets | length > 0 and all(.health == \"up\")'";
      };
    };

    machine.serviceCommands.prometheus.unit = "prometheus.service";
  };
}
