# node_exporter: CPU, memory, disks, network and the state of every systemd
# service, for Prometheus. It listens on localhost only.
{ config, lib, ... }:

let
  cfg = config.services.prometheus.exporters.node;
in
{
  config = lib.mkMerge [
    # Set whether or not it is on: these are in the same submodule as its
    # enable option, so making them depend on it would be infinite recursion.
    {
      services.prometheus.exporters.node = {
        listenAddress = "127.0.0.1";
        port = 9100;
        enabledCollectors = [ "systemd" ];
        # These go into ExecStart as they are, so no backslashes, and $$ for $.
        extraFlags = [
          "--collector.systemd.unit-include=.+[.]service"
          # The local volumes only. endor's shares would hang the collector
          # whenever endor is down.
          "--collector.filesystem.fs-types-include=^(ext4|vfat)$$"
        ];
      };
    }

    (lib.mkIf cfg.enable {
      # The module hides /home from the exporter, which then reports the space of
      # the empty directory put over it rather than of the /home volume.
      systemd.services.prometheus-node-exporter.serviceConfig.ProtectHome = lib.mkForce "read-only";
      # It only reads; its RuntimeDirectory is all it writes.
      machine.sandbox.prometheus-node-exporter = { };

      machine.healthchecks.checks.prometheus-node-exporter = {
        type = "unit";
        target = "prometheus-node-exporter.service";
      };
    })
  ];
}
