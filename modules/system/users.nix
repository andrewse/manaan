{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.machine.users = lib.mkOption {
    type = with lib.types; attrsOf (listOf str);
    default = { };
    description = "Admin users and their SSH public keys. Every key can also push to the git server.";
  };

  config = {
    users.mutableUsers = false;
    users.defaultUserShell = pkgs.zsh;
    security.sudo.wheelNeedsPassword = false;

    users.users =
      lib.mapAttrs (_: keys: {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = keys;
      }) config.machine.users
      // {
        # Break-glass login on the TrueNAS console for when the network is down,
        # once an admin has put a hash there (`mkpasswd -m yescrypt`); until then
        # root is locked. root can never log in over SSH.
        root.hashedPasswordFile = "/etc/credstore/root-password";
      };
    # To make that hash on the machine itself.
    environment.systemPackages = [ pkgs.mkpasswd ];
  };
}
