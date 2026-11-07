# Secrets are agenix files in secrets/, encrypted to the admins and the host's
# SSH host key (see secrets/secrets.nix). A module names the secrets it uses in
# machine.secrets.use and reads them from machine.secrets.paths, which only has
# those whose .age file exists, so the repo builds before any secrets have been
# created.
{ config, lib, ... }:

let
  cfg = config.machine.secrets;
  dir = ../../secrets;
  existing = lib.filter (name: cfg.enable && builtins.pathExists (dir + "/${name}.age")) (
    lib.unique cfg.use
  );
in
{
  options.machine.secrets = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to decrypt secrets. Off in VM tests, which have no host key to decrypt with.";
    };
    use = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Secrets the host's modules use, by name: secrets/<name>.age.";
    };
    paths = lib.mkOption {
      type = with lib.types; attrsOf str;
      readOnly = true;
      default = lib.genAttrs existing (name: config.age.secrets.${name}.path);
      defaultText = lib.literalMD "the decrypted path of each secret in `use` whose file exists";
      description = "Where each secret in `use` is decrypted to, by name, once its file exists.";
    };
  };

  config.age.secrets = lib.genAttrs existing (name: {
    file = dir + "/${name}.age";
  });
}
