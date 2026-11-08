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
  jobs = lib.filter (job: job.enable) [
    {
      name = "node";
      inherit (cfg.exporters.node) enable port;
    }
    {
      name = "cadvisor";
      inherit (config.services.cadvisor) enable port;
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
    services.prometheus = {
      listenAddress = "127.0.0.1";
      port = 9090;
      # /var is 10G and shared; whichever limit comes first.
      retentionTime = "90d";
      extraFlags = [ "--storage.tsdb.retention.size=2GB" ];
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
        type = "command";
        target = "${lib.getExe pkgs.curl} -sf http://${local cfg.port}/api/v1/targets | ${lib.getExe pkgs.jq} -e '.data.activeTargets | length > 0 and all(.health == \"up\")'";
      };
    };

    machine.serviceCommands.prometheus.unit = "prometheus.service";
  };
}
