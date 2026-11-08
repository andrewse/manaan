# Partitioning for the zvol, written by the installer ISO. Each mount is its own
# LVM volume so one filling up can't fill the others. Sized for a 200G zvol, which
# it all but fills: about 1G is left for the partition table and LVM's metadata.
# To grow a volume, enlarge the zvol first (see README). ext4 rather than a
# copy-on-write filesystem: the zvol is already CoW and is snapshotted by TrueNAS.
let
  ext4 = mountpoint: options: {
    type = "filesystem";
    format = "ext4";
    inherit mountpoint;
    mountOptions = [ "defaults" ] ++ options;
  };
in
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/vda";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          pool = {
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "pool";
            };
          };
        };
      };
    };

    lvm_vg.pool = {
      type = "lvm_vg";
      lvs = {
        root = {
          size = "6G";
          content = ext4 "/" [ ];
        };
        # Grows with every system generation; garbage collected weekly.
        nix = {
          size = "30G";
          content = ext4 "/nix" [ "noatime" ];
        };
        # Most services' state (Sonarr, Radarr, SABnzbd, NZBHydra2, Gatus,
        # Syncthing's database) and the journal share it.
        var = {
          size = "23G";
          content = ext4 "/var" [ "nodev" ];
        };
        home = {
          size = "8G";
          content = ext4 "/home" [
            "nodev"
            "nosuid"
          ];
        };
        # Images, containers and named volumes, so they can't fill /var.
        docker = {
          size = "100G";
          content = ext4 "/var/lib/docker" [ ];
        };
        # Grafana's database: users, sessions, annotations. Tens of MB; the
        # dashboards are provisioned from the store, so the rest is headroom.
        grafana = {
          size = "5G";
          content = ext4 "/var/lib/grafana" [
            "nodev"
            "nosuid"
          ];
        };
        # Prometheus's TSDB, capped at 16GB by its retention; the rest is room
        # for compaction, which writes a new block before deleting the old ones.
        prometheus = {
          size = "20G";
          content = ext4 "/var/lib/prometheus2" [
            "nodev"
            "nosuid"
          ];
        };
        tmp = {
          size = "4G";
          content = ext4 "/tmp" [
            "nodev"
            "nosuid"
          ];
        };
        # Small on purpose: room to survive a memory spike, not to run in.
        swap = {
          size = "2G";
          content.type = "swap";
        };
      };
    };
  };
}
