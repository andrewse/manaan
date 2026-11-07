# The machine's Grafana dashboard, a row per file: the machine itself (CPU,
# memory, disks and network), its services (whether each healthchecked unit
# is up, and CPU and memory per systemd service) and, with Docker, CPU and
# memory per container.
{
  lib,
  title,
  units,
  docker,
}:

let
  panels = import ./panels.nix { inherit lib; };
in
{
  inherit title;
  uid = "machine";
  tags = [ "machine" ];
  timezone = "browser";
  refresh = "30s";
  time = {
    from = "now-6h";
    to = "now";
  };
  schemaVersion = 39;
  panels =
    import ./machine.nix { inherit panels; }
    ++ import ./services.nix { inherit lib panels units; }
    ++ lib.optionals docker (import ./containers.nix { inherit panels; });
}
