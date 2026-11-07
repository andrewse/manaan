# CPU, memory, swap, load, uptime, failed services, disks and network.
{ panels }:

let
  inherit (panels)
    panel
    row
    stat
    timeseries
    q
    usage
    ;
  cpus = ''count(node_cpu_seconds_total{mode="idle"})'';
  disks = ''device!~"dm-.+|sr.+"'';
  interfaces = ''device!~"lo|veth.+|docker.+|br-.+"'';
in
[
  (row "Machine" 0)
  (stat {
    title = "CPU busy";
    x = 0;
    y = 1;
    w = 4;
    h = 4;
    unit = "percent";
    min = 0;
    max = 100;
    thresholds = usage;
    targets = [
      (q ''100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval])))'' "")
    ];
  })
  (stat {
    title = "Memory used";
    x = 4;
    y = 1;
    w = 4;
    h = 4;
    unit = "percent";
    min = 0;
    max = 100;
    thresholds = usage;
    targets = [ (q "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)" "") ];
  })
  (stat {
    title = "Swap used";
    x = 8;
    y = 1;
    w = 4;
    h = 4;
    unit = "bytes";
    targets = [ (q "node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes" "") ];
  })
  (stat {
    title = "Load per CPU (5m)";
    x = 12;
    y = 1;
    w = 4;
    h = 4;
    unit = "none";
    thresholds = [
      { color = "green"; }
      {
        color = "orange";
        value = 1;
      }
      {
        color = "red";
        value = 2;
      }
    ];
    targets = [ (q "node_load5 / scalar(${cpus})" "") ];
  })
  (stat {
    title = "Up for";
    x = 16;
    y = 1;
    w = 4;
    h = 4;
    unit = "s";
    options = {
      colorMode = "none";
      graphMode = "none";
      reduceOptions.calcs = [ "lastNotNull" ];
    };
    targets = [ (q "time() - node_boot_time_seconds" "") ];
  })
  (stat {
    title = "Failed services";
    x = 20;
    y = 1;
    w = 4;
    h = 4;
    thresholds = [
      { color = "green"; }
      {
        color = "red";
        value = 1;
      }
    ];
    options = {
      colorMode = "background";
      graphMode = "none";
      reduceOptions.calcs = [ "lastNotNull" ];
    };
    targets = [ (q ''count(node_systemd_unit_state{state="failed"} == 1) or vector(0)'' "") ];
  })
  (timeseries {
    title = "CPU";
    x = 0;
    y = 5;
    w = 12;
    h = 8;
    unit = "percentunit";
    min = 0;
    max = 1;
    custom.stacking.mode = "normal";
    targets = [
      (q ''sum by (mode) (rate(node_cpu_seconds_total{mode!="idle"}[$__rate_interval])) / scalar(${cpus})'' "{{mode}}")
    ];
  })
  (timeseries {
    title = "Memory";
    x = 12;
    y = 5;
    w = 12;
    h = 8;
    unit = "bytes";
    min = 0;
    targets = [
      (q "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes" "used")
      (q "node_memory_Cached_bytes + node_memory_Buffers_bytes" "cache")
      (q "node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes" "swap")
      (q "node_memory_MemTotal_bytes" "total")
    ];
  })
  (panel {
    type = "bargauge";
    title = "Disk space used";
    x = 0;
    y = 13;
    w = 8;
    h = 8;
    unit = "percent";
    min = 0;
    max = 100;
    thresholds = usage;
    options = {
      displayMode = "gradient";
      orientation = "horizontal";
      showUnfilled = true;
      reduceOptions.calcs = [ "lastNotNull" ];
    };
    targets = [
      (q "100 * (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes)" "{{mountpoint}}")
    ];
  })
  (timeseries {
    title = "Disk I/O";
    x = 8;
    y = 13;
    w = 8;
    h = 8;
    unit = "Bps";
    targets = [
      (q "rate(node_disk_read_bytes_total{${disks}}[$__rate_interval])" "{{device}} read")
      (q "rate(node_disk_written_bytes_total{${disks}}[$__rate_interval])" "{{device}} written")
    ];
  })
  (timeseries {
    title = "Network";
    x = 16;
    y = 13;
    w = 8;
    h = 8;
    unit = "Bps";
    targets = [
      (q "rate(node_network_receive_bytes_total{${interfaces}}[$__rate_interval])" "{{device}} in")
      (q "rate(node_network_transmit_bytes_total{${interfaces}}[$__rate_interval])" "{{device}} out")
    ];
  })
]
