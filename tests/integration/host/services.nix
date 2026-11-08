# How a host's services are watched: the healthchecks, the service commands,
# and the monitoring, each naming units and ports other modules declare.
{ lib, config }:

let
  services = config.systemd.services;
  health = config.machine.healthchecks;
  hasUnit = unit: config.systemd.units ? ${unit};
  unitChecks = lib.filterAttrs (_: check: check.enable && check.type == "unit") health.checks;
  # Gatus can only poll a check that connects or fetches; a check is already
  # off when what it checks doesn't start at boot.
  pollableChecks = lib.filterAttrs (
    _: check: check.enable && (check.type == "tcp" || check.type == "http")
  ) health.checks;
  prometheus = config.services.prometheus;
  grafana = config.services.grafana;
  # A unit a host says not to start at boot is neither watched nor scraped.
  # Before hosts could say so, every unit started.
  starts = unit: config.machine.autostart.${unit} or true;

  # Every datasource uid a dashboard's panels and queries name.
  datasources =
    value:
    if lib.isAttrs value then
      lib.optional (value ? datasource.uid) value.datasource.uid
      ++ lib.concatMap datasources (lib.attrValues value)
    else if lib.isList value then
      lib.concatMap datasources value
    else
      [ ];
in
{
  "each unit a healthcheck waits for is one the host has" = {
    expr = lib.attrNames (lib.filterAttrs (_: check: !hasUnit check.target) unitChecks);
    expected = [ ];
  };

  "each service with a health URL is held in activating until it answers" = {
    expr = lib.attrNames (
      lib.filterAttrs (
        unit: _:
        !lib.any (lib.hasInfix "/bin/wait-healthy") (
          lib.toList (services.${unit}.serviceConfig.ExecStartPost or [ ])
        )
      ) health.services
    );
    expected = [ ];
  };

  "each service command's unit is one the host has" = {
    expr = lib.attrNames (
      lib.filterAttrs (
        _: command: command.unit != null && !hasUnit command.unit
      ) config.machine.serviceCommands
    );
    expected = [ ];
  };
}
// lib.optionalAttrs config.services.gatus.enable {
  "Gatus watches each other service and each tcp or http check that starts at boot" = {
    expr = lib.sort lib.lessThan (map (e: e.name) config.services.gatus.settings.endpoints);
    expected = lib.sort lib.lessThan (
      lib.filter (unit: unit != "gatus" && starts unit) (lib.attrNames health.services)
      ++ lib.attrNames pollableChecks
    );
  };

  # Gatus refuses to start with none.
  "Gatus has at least one endpoint" = {
    expr = config.services.gatus.settings.endpoints != [ ];
    expected = true;
  };
}
// lib.optionalAttrs prometheus.enable {
  "Prometheus scrapes itself and every exporter that is on and starts at boot" = {
    expr = lib.sort lib.lessThan (
      lib.concatMap (job: lib.concatMap (s: s.targets) job.static_configs) prometheus.scrapeConfigs
    );
    expected = lib.sort lib.lessThan (
      map (port: "127.0.0.1:${toString port}") (
        [ prometheus.port ]
        ++ lib.optional (
          prometheus.exporters.node.enable && starts "prometheus-node-exporter"
        ) prometheus.exporters.node.port
        ++ lib.optional (config.services.cadvisor.enable && starts "cadvisor") config.services.cadvisor.port
      )
    );
  };
}
// lib.optionalAttrs grafana.enable {
  "the dashboard only uses data sources Grafana is given" = {
    expr =
      let
        dashboard = import ../../../modules/services/grafana/dashboard {
          inherit lib;
          title = config.networking.hostName;
          docker = config.virtualisation.docker.enable;
          units = lib.mapAttrsToList (_: check: check.target) unitChecks;
        };
        provided = map (d: d.uid) grafana.provision.datasources.settings.datasources;
      in
      lib.filter (uid: !lib.elem uid provided) (lib.unique (datasources dashboard));
    expected = [ ];
  };
}
