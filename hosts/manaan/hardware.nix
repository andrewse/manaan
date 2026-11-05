# TrueNAS SCALE VM: KVM/QEMU with UEFI firmware and a VirtIO zvol as its disk.
{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
  ];

  services.qemuGuest.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # TrueNAS offers both a display and a serial shell for the VM.
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200"
  ];

}
