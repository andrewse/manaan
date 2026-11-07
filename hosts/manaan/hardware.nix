# TrueNAS SCALE VM: KVM/QEMU with UEFI firmware and a VirtIO zvol as its disk.
{ modulesPath, pkgs, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
  ];

  services.qemuGuest.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # TrueNAS offers both a display and a serial shell for the VM. The serial
  # port is ttyAMA0 on arm64, where the tests also run.
  boot.kernelParams = [
    "console=tty0"
    "console=${if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0"},115200"
  ];

  # Hand deleted blocks back to the zvol, or it only ever grows on the TrueNAS side.
  services.fstrim.enable = true;

  # Swap is a last resort against the OOM killer, not somewhere to page to routinely.
  boot.kernel.sysctl."vm.swappiness" = 10;

  boot.tmp.cleanOnBoot = true;

  # growpart, for taking up space after the zvol is enlarged (see README).
  environment.systemPackages = [ pkgs.cloud-utils ];
}
