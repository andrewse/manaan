{
  imports = [
    ./common.nix
    ./secrets.nix
    ./users.nix
    ./ssh.nix
    ./tailscale.nix
    ./git-server
    ./smoke-tests
  ];
}
