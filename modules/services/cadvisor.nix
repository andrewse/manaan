# cAdvisor: CPU and memory per systemd service and per Docker container, for
# Prometheus. It listens on localhost only.
{ config, lib, ... }:

let
  cfg = config.services.cadvisor;
in
{
  config = lib.mkIf cfg.enable {
    machine.autostart.cadvisor = lib.mkDefault false;

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

    # Root, to read every container's cgroup and Docker's own state. A user of
    # its own would need the docker group, which is root in all but name, so
    # it would gain nothing; it can still write nothing.
    machine.sandbox.cadvisor.root = true;

    machine.healthchecks.checks.cadvisor = {
      type = "unit";
      target = "cadvisor.service";
    };

    machine.serviceCommands.cadvisor.unit = "cadvisor.service";
  };
}
