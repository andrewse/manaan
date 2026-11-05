{
  imports = [ ./hardware.nix ];

  machine.users = import ../../keys.nix;
  machine.gitServer.enable = true;

  # The release this machine was first installed with. Never change it after
  # install; it is not the nixpkgs version (that comes from flake.lock).
  system.stateVersion = "26.05";
}
