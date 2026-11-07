{
  imports = [
    ./common.nix
    ./secrets.nix
    ./users.nix
    ./firewall.nix
    ./ssh.nix
    ./tailscale.nix
    ./docker.nix
    ./monitoring
    ./git-server
    ./self-upgrade
  ];
}
