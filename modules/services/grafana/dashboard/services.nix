# Whether each healthchecked unit is up, and CPU and memory per systemd service.
{
  lib,
  panels,
  units,
}:

let
  inherit (panels)
    row
    stat
    timeseries
    q
    ;
  services = ''id=~"/system.slice/.+\\.service"'';
  byService =
    expr:
    ''sum by (service) (label_replace(${expr}, "service", "$1", "id", "/system.slice/(.+)\\.service"))'';
  # PromQL strings take Go escapes, so the regex's backslashes are doubled.
  unitsRegex = lib.concatMapStringsSep "|" (
    u: lib.replaceStrings [ "\\" ] [ "\\\\" ] (lib.escapeRegex u)
  ) units;
in
[
  (row "Services" 21)
  (stat {
    title = "Healthchecked units";
    x = 0;
    y = 22;
    w = 24;
    h = 4;
    mappings = [
      {
        type = "value";
        options = {
          "1" = {
            text = "up";
            color = "green";
          };
          "0" = {
            text = "down";
            color = "red";
          };
        };
      }
    ];
    options = {
      colorMode = "background";
      graphMode = "none";
      textMode = "value_and_name";
      reduceOptions.calcs = [ "lastNotNull" ];
    };
    targets = [
      (q ''max by (name) (node_systemd_unit_state{state="active", name=~"${unitsRegex}"})'' "{{name}}")
    ];
  })
  (timeseries {
    title = "CPU by service (cores)";
    x = 0;
    y = 26;
    w = 12;
    h = 10;
    unit = "none";
    min = 0;
    targets = [
      (q (byService "rate(container_cpu_usage_seconds_total{${services}}[$__rate_interval])") "{{service}}")
    ];
  })
  (timeseries {
    title = "Memory by service";
    x = 12;
    y = 26;
    w = 12;
    h = 10;
    unit = "bytes";
    min = 0;
    targets = [ (q (byService "container_memory_working_set_bytes{${services}}") "{{service}}") ];
  })
]
