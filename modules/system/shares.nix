# Whether a host's network shares are stood in for by local directories. A host
# reads it where it mounts them; the system tests switch it on, having no file
# server to mount from.
{ lib, ... }:

{
  options.machine.localShares = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    description = "Local directories in place of the shares this host mounts from other machines. On in the system tests.";
  };
}
