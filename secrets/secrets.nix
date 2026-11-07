# Read by the agenix CLI (`make secret NAME=...`, `make rekey`), not by NixOS.
# Each secret is encrypted to the admins plus every host that needs it. A host's
# public key appears in hosts/<host>/host_key.pub after `make enroll HOST=<host>`;
# until then the host boots without its secrets.
let
  admins = (import ../keys.nix).charles;
  hostKey =
    host:
    let
      file = ../hosts + "/${host}/host_key.pub";
    in
    if builtins.pathExists file then
      [ (builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile file)) ]
    else
      [ ];
  forHosts = hosts: { publicKeys = admins ++ builtins.concatMap hostKey hosts; };
in
{
  "tailscale-authkey.age" = forHosts [ "manaan" ];
  "root-password.age" = forHosts [ "manaan" ];
  "smb-credentials.age" = forHosts [ "manaan" ];
  "syncthing-key.age" = forHosts [ "manaan" ];
  "syncthing-https-key.age" = forHosts [ "manaan" ];
}
