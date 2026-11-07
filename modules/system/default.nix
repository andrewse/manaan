# The OS itself, on every host.
{
  imports = [
    ./common.nix
    ./secrets.nix
    ./users.nix
    ./firewall.nix
    ./notify.nix
  ];
}
