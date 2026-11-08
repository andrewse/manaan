# The OS itself, on every host.
{
  imports = [
    ./common.nix
    ./secrets.nix
    ./users.nix
    ./firewall.nix
    ./sandbox.nix
    ./notify.nix
  ];
}
