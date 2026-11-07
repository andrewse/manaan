# Installer ISO for one host. Booted next to a blank disk, it formats the disk
# with the host's disko layout, installs the host from the ISO's own store (no
# network needed) and reboots into it. A disk with any partition table or
# filesystem on it is never touched, so leaving the ISO attached is safe.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  target = config.machine.installer.target.config;
  host = target.networking.hostName;

  script = pkgs.writeShellApplication {
    name = "auto-install";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.lvm2
      pkgs.openssh
      config.nix.package
      config.system.build.nixos-install
      config.systemd.package
    ];
    text =
      lib.toShellVars {
        inherit host;
        efi = "/sys/firmware/efi";
        system = target.system.build.toplevel;
        disko = target.system.build.diskoScript;
        disks = lib.catAttrs "device" (lib.attrValues target.disko.devices.disk);
      }
      + "\n"
      + builtins.readFile ./install.sh;
  };
in
{
  options.machine.installer.target = lib.mkOption {
    type = lib.types.raw;
    description = "The evaluated NixOS system (a nixosSystem result) this ISO installs.";
  };

  config = {
    image.baseName = lib.mkForce "${host}-installer";
    isoImage.squashfsCompression = "zstd -Xcompression-level 6";
    # The target is ext4 on a zvol; the stock ISO's ZFS support isn't needed.
    boot.supportedFilesystems.zfs = lib.mkForce false;

    # Same consoles as the installed host: TrueNAS display and serial shell.
    boot.kernelParams = [
      "console=tty0"
      "console=${if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0"},115200"
    ];
    services.getty.helpLine = ''
      This ISO installs ${host} onto a blank disk by itself. Follow along with:
        journalctl -fu auto-install
    '';

    systemd.services.auto-install = {
      description = "Install ${host} onto a blank disk";
      wantedBy = [ "multi-user.target" ];
      # disko and nixos-install expect the tools of an interactive installer shell
      # (disko calls modprobe for LVM, for one); a service's PATH is minimal.
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe script;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };
  };
}
