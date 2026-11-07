{
  imports = [
    ./common.nix
    ./secrets.nix
    ./users.nix
    ./firewall.nix
    ./ssh.nix
    ./tailscale.nix
    ./docker.nix
    ./git-server
    ./smoke-tests
    ./self-upgrade
  ];
}
