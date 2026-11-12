# Syncthing's part of generate.sh and login.sh, which run in units of their
# own once Syncthing has started. The login goes in through the REST API, with
# the API key from config.xml; Syncthing bcrypts a plaintext password itself.
# Prepended by default.nix with config_dir= and address= (host:port of the GUI).

# xml <path>: the text at that path in config.xml.
xml() {
  xmllint --xpath "string($1)" "$config_dir/config.xml" 2>/dev/null || true
}

# Syncthing writes config.xml as it starts, the first time with a new API key.
has_login() {
  local tries
  for ((tries = 1; ; tries++)); do
    [[ -z $(xml configuration/gui/apikey) ]] || break
    if ((tries == 300)); then
      echo "no API key in $config_dir/config.xml" >&2
      exit 1
    fi
    sleep 1
  done
  [[ -n $(xml configuration/gui/user) || -n $(xml configuration/gui/password) ]]
}

set_login() {
  local api_key
  api_key=$(xml configuration/gui/apikey)
  # In the environment and on stdin, not in an argument any user can read.
  username=$username password=$password jq --null-input '{user: env.username, password: env.password}' |
    curl --silent --show-error --fail --retry 300 --retry-delay 1 --retry-all-errors \
      --header @<(printf 'X-API-Key: %s\n' "$api_key") \
      --request PATCH --json @- "http://$address/rest/config/gui"
  echo "Syncthing's GUI login is $username"
}

no_login() { :; }
