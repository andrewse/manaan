# Installer ISO for one host. Booted next to a blank disk, it formats the disk
# with the host's disko layout, installs the host from the ISO's own store (no
# network needed) and reboots into it. A disk with any partition table or
# filesystem on it is never touched, so leaving the ISO attached is safe. The
# host's admins can SSH in to follow the install.
{
  config,
  lib,
  pkgs,
  machineLib,
  ...
}:

let
  target = config.machine.installer.target.config;
  host = target.networking.hostName;
  # The ISO's sshd serves this key, and the install copies it onto the host, so
  # the host answers with the same key before and after the reboot.
  hostKey = "/etc/ssh/ssh_host_ed25519_key";

  script = machineLib.mkScript {
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
    vars = {
      inherit host hostKey;
      efi = "/sys/firmware/efi";
      system = target.system.build.toplevel;
      disko = target.system.build.diskoScript;
      disks = lib.catAttrs "device" (lib.attrValues target.disko.devices.disk);
    };
    parts = [ ./install.sh ];
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
    # Replaces the installer profile's, which says to set a password for SSH.
    services.getty.helpLine = lib.mkForce ''
      This ISO installs ${host} onto a blank disk by itself. Follow along with:
        journalctl -fu auto-install
      here, or over SSH as one of ${host}'s admins: ${lib.concatStringsSep ", " (lib.attrNames target.machine.users)}.
    '';

    # The installer profile already runs sshd; let the host's admins in, as on
    # the host: by key only, with passwordless sudo, and never as root.
    services.openssh = {
      hostKeys = [
        {
          type = "ed25519";
          path = hostKey;
          comment = "root@${host}";
        }
      ];
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
    users.users = lib.mapAttrs (_: keys: {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = keys;
    }) target.machine.users;

    systemd.services.auto-install = {
      description = "Install ${host} onto a blank disk";
      wantedBy = [ "multi-user.target" ];
      # The host key it installs is the one sshd-keygen makes.
      wants = [ "sshd-keygen.service" ];
      after = [ "sshd-keygen.service" ];
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
