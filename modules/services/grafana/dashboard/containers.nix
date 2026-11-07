# CPU and memory per Docker container.
{ panels }:

let
  inherit (panels) row timeseries q;
  containers = ''name!=""'';
in
[
  (row "Docker containers" 36)
  (timeseries {
    title = "CPU by container (cores)";
    x = 0;
    y = 37;
    w = 12;
    h = 10;
    unit = "none";
    min = 0;
    targets = [
      (q "sum by (name) (rate(container_cpu_usage_seconds_total{${containers}}[$__rate_interval]))" "{{name}}")
    ];
  })
  (timeseries {
    title = "Memory by container";
    x = 12;
    y = 37;
    w = 12;
    h = 10;
    unit = "bytes";
    min = 0;
    targets = [ (q "sum by (name) (container_memory_working_set_bytes{${containers}})" "{{name}}") ];
  })
]
