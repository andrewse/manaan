# cAdvisor: CPU and memory per systemd service and per Docker container, for
# Prometheus. It listens on localhost only.
{ config, lib, ... }:

let
  cfg = config.services.cadvisor;
in
{
  config = lib.mkIf cfg.enable {
    services.cadvisor = {
      listenAddress = "127.0.0.1";
      port = 9338; # cAdvisor's default 8080 is SABnzbd's.
      extraOptions = [
        "-enable_metrics=cpu,memory,diskIO,network"
        # Container name and image only, not every label and environment variable.
        "-store_container_labels=false"
        # Prometheus only looks every 15s; the default 1s costs a lot of CPU.
        "-housekeeping_interval=15s"
      ];
    };

    machine.healthchecks.checks.cadvisor = {
      type = "unit";
      target = "cadvisor.service";
    };
  };
}
