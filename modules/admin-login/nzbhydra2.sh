# NZBHydra2's part of generate.sh and login.sh, which run before it starts.
# The login is a form login for one user who may do everything, with every
# part of the UI restricted to logged-in users; the API still goes by its key,
# and its health ping stays open. The password is stored bcrypted, as
# NZBHydra2 stores one set in its UI.
#
# NZBHydra2 only writes nzbhydra.yml on its first start, from the base config
# in its jar, and refuses one without the rest of the settings; so before
# that, set_login writes the same base config, which NZBHydra2 then
# initializes as it would its own. Prepended by default.nix with config= and
# base= (the base config, from NZBHydra2's source).

# An auth type, or users with auth switched off in the web UI.
has_login() {
  [[ -e $config ]] &&
    [[ $(yq '.auth.authType != "NONE" or (.auth.users // [] | length) > 0' "$config") == true ]]
}

set_login() {
  local hash
  [[ -e $config ]] || install -m 600 "$base" "$config"
  hash=$(printf '%s\n' "$password" | mkpasswd --method=bcrypt --rounds=10 --stdin)
  username=$username hash="{bcrypt}$hash" yq --inplace '
    .auth.authType = "FORM" |
    .auth.restrictAdmin = true |
    .auth.restrictDetailsDl = true |
    .auth.restrictIndexerSelection = true |
    .auth.restrictSearch = true |
    .auth.restrictStats = true |
    .auth.users = [{
      "username": strenv(username),
      "password": strenv(hash),
      "maySeeAdmin": true,
      "maySeeDetailsDl": true,
      "maySeeStats": true,
      "showIndexerSelection": true
    }]' "$config"
  echo "NZBHydra2's login is $username"
}

no_login() { :; }
