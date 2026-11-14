# The OS itself, on every host.
{
  imports = [
    ./common.nix
    ./users.nix
    ./firewall.nix
    ./sandbox.nix
    ./notify.nix
    ./autostart.nix
    ./shares.nix
  ];
}
