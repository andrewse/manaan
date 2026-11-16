# What the installer ISO takes from the host it installs.
{ lib, evalModules }:

let
  iso = evalModules [
    (
      { modulesPath, ... }:
      {
        imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];
      }
    )
    ./default.nix
    {
      machine.installer.target.config = {
        networking.hostName = "testhost";
        machine.users = { };
      };
    }
  ];
in
{
  "the host's name, sent with the ISO's DHCP requests" = {
    expr = iso.networking.hostName;
    expected = "testhost";
  };
}
