# Admin users and their SSH public keys: every other file in this directory is
# named after a user and holds their keys in authorized_keys format. Each user
# gets an account with passwordless sudo, and every key can push to the git
# server.
let
  entries = builtins.readDir ./.;
  users = builtins.filter (
    name: entries.${name} == "regular" && name != "default.nix" && builtins.substring 0 1 name != "."
  ) (builtins.attrNames entries);
  # Every line except blanks and comments.
  keys =
    user:
    builtins.filter (line: builtins.isString line && builtins.match "[[:space:]]*(#.*)?" line == null) (
      builtins.split "\n" (builtins.readFile (./. + "/${user}"))
    );
in
builtins.listToAttrs (
  map (user: {
    name = user;
    value = keys user;
  }) users
)
