{
  imports = [
    ./hardware.nix
    ./mounts.nix
    ./syncthing.nix
    ./media.nix
  ];

  machine.users = import ../../ssh;
  machine.gitServer.enable = true;
  machine.selfUpgrade.enable = true;
  machine.docker.enable = true;

  # The same ID as on the old host, so files on endor's NFS shares stay charles's.
  users.users.charles.uid = 1000;

  # The release this machine was first installed with. Never change it after
  # install; it is not the nixpkgs version (that comes from flake.lock).
  system.stateVersion = "26.05";
}
