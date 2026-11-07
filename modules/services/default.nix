# One file (or directory) per app or service. Each does nothing until it is
# switched on, except SSH and Tailscale, which every host runs.
{
  imports = [
    ./ssh.nix
    ./tailscale.nix
    ./docker.nix
    ./git-server
    ./prometheus.nix
    ./node-exporter.nix
    ./cadvisor.nix
    ./grafana
    ./gatus.nix
  ];
}
