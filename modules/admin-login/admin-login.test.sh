# shellcheck shell=bash disable=SC2016 # stub bodies expand in the stub
# What each service's two admin login steps do, run one after the other as
# their units run them, with systemd's ImportCredential= in between: a service
# with no login is given `admin` and a random password, kept in a file only
# root may read, or the one already kept there; a service with a login of its
# own is left alone, and no file is made. jq, yq and mkpasswd are the real
# ones; Syncthing is stubbed.
#
#   admin-login.test.sh <PATH with jq, yq and mkpasswd> <NZBHydra2's baseConfig.yml>

# On PATH; see tests/script-test.nix.
source script-harness.sh
# The scripts, beside this file.
scripts=$(dirname "$0")
PATH=$1:$PATH
base=$2

# start <service> <variable>=<value>...: runs the service's two steps, as
# default.nix assembles them, with these variables prepended: the generator,
# then what ImportCredential= does, the credential if it is kept, then the
# step that sets it. The kept login is at $root/credstore/<service>-admin.
start() {
  local service=$1 vars
  shift
  vars=$(printf '%q ' service="$service" file="$root/credstore/$service-admin" \
    credential="$service-admin" CREDENTIALS_DIRECTORY="$root/credentials" "$@")
  echo 'mkdir -p "$CREDENTIALS_DIRECTORY"; [[ ! -e $file ]] || cp "$file" "$CREDENTIALS_DIRECTORY/$credential"' \
    >"$root/import.sh"
  run "$vars" "$scripts/$service.sh" "$scripts/generate.sh" "$root/import.sh" \
    "$scripts/$service.sh" "$scripts/login.sh"
}

# kept <service> <password>: a login an earlier start kept for the service.
kept() {
  mkdir -p "$root/credstore"
  printf 'username=admin\npassword=%s\n' "$2" >"$root/credstore/$1-admin"
}

# password <service>: the password kept for the service.
password() {
  sed -n 's/^password=//p' "$root/credstore/$1-admin"
}

# expect_kept <service>: a login for admin, with a new random password, kept
# where only its owner may read it.
expect_kept() {
  local file=$root/credstore/$1-admin
  [[ -f $file ]] || fail "no login kept for $1"
  [[ $(stat -c %a "$file") == 600 ]] || fail "$file is $(stat -c %a "$file"), not 600"
  [[ $(stat -c %a "${file%/*}") == 700 ]] || fail "${file%/*} is $(stat -c %a "${file%/*}"), not 700"
  [[ $(sed -n 1p "$file") == username=admin ]] || fail "$file's username is not admin"
  [[ $(password "$1") =~ ^[A-Za-z0-9]{32}$ ]] || fail "$file's password is '$(password "$1")'"
}

# hex <string>: as SABnzbd encodes it.
hex() {
  printf %s "$1" | od -An -v -tx1 | tr -d ' \n'
}

# --- SABnzbd

sabnzbd() {
  start sabnzbd ini="$root/sabnzbd.ini" out="$root/admin-login.ini"
}

begin "SABnzbd, no sabnzbd.ini yet: a login is made, kept, and written for the module to merge"
sabnzbd
expect_status 0
expect_kept sabnzbd
expect_file admin-login.ini "[misc]
username = admin
password = !!!encoded!!!$(hex "$(password sabnzbd)")"
expect_output "made a login for sabnzbd in $root/credstore/sabnzbd-admin"

begin "SABnzbd, an empty login in sabnzbd.ini, as SABnzbd writes it: a login is made"
cat >"$root/sabnzbd.ini" <<'EOF'
__version__ = 19
[misc]
username = ""
password = ""
port = 8080
EOF
sabnzbd
expect_status 0
expect_kept sabnzbd
expect_output "SABnzbd's login is admin"

begin "SABnzbd, a login only for a news server: not SABnzbd's, so a login is made"
cat >"$root/sabnzbd.ini" <<'EOF'
[misc]
port = 8080
[servers]
[[news.example.com]]
username = someone
password = theirs
EOF
sabnzbd
expect_status 0
expect_kept sabnzbd

begin "SABnzbd, its state gone but the login kept: the kept one is set again"
kept sabnzbd 'a "pass" # word'
sabnzbd
expect_status 0
expect_file admin-login.ini '[misc]
username = admin
password = !!!encoded!!!6120227061737322202320776f7264'
[[ $(password sabnzbd) == 'a "pass" # word' ]] || fail "the kept login changed"
expect_output "sabnzbd has no login; the one kept in $root/credstore/sabnzbd-admin will be set again"

begin "SABnzbd, a login of its own: left alone, with no login kept and nothing to merge"
cat >"$root/sabnzbd.ini" <<'EOF'
[misc]
username = charles
password = theirs
EOF
sabnzbd
expect_status 0
expect_missing credstore/sabnzbd-admin
expect_file admin-login.ini ''
expect_output "sabnzbd has a login already; leaving it"

begin "SABnzbd, a login made by an earlier start, still kept: left alone, the kept one too"
kept sabnzbd secret
cat >"$root/sabnzbd.ini" <<'EOF'
[misc]
username = admin
password = secret
EOF
sabnzbd
expect_status 0
expect_file admin-login.ini ''
[[ $(password sabnzbd) == secret ]] || fail "the kept login changed"

begin "SABnzbd, a kept login with a password its encoding can't hold: refused"
kept sabnzbd 'sécret'
sabnzbd
expect_failure
expect_output "SABnzbd's password may only have printable ASCII characters"
expect_missing admin-login.ini

begin "a kept login with no password: refused, rather than set an empty one"
mkdir -p "$root/credstore"
echo username=admin >"$root/credstore/sabnzbd-admin"
sabnzbd
expect_failure
expect_output "the login needs a username= line and a password= line"
expect_missing admin-login.ini

# --- Syncthing

# syncthing [xmllint commands]: runs Syncthing's steps against a stubbed
# config.xml, which has the API key and no GUI login unless the commands say
# otherwise, and a stubbed API, which keeps the header file curl was given in
# $root/header and the request body in $root/body.
syncthing() {
  stub "$root/bin/xmllint" xmllint "${1:-[[ \$2 != *apikey* ]] || echo the-api-key}"
  stub "$root/bin/sleep" sleep
  stub "$root/bin/curl" curl '
while (($#)); do
  [[ $1 != --header ]] || cat "${2#@}" >"$root/header"
  shift
done
cat >"$root/body"'
  start syncthing config_dir="$root/syncthing" address=0.0.0.0:8384
}

begin "Syncthing, no GUI login: a login is made, kept, and sent to its API with the API key"
syncthing
expect_status 0
expect_kept syncthing
expect_called "xmllint --xpath string\(configuration/gui/user\) $root/syncthing/config.xml"
grep -qF -- "--request PATCH --json @- http://0.0.0.0:8384/rest/config/gui" "$root/calls" ||
  fail "no PATCH of the GUI settings"
expect_file header "X-API-Key: the-api-key"
[[ $(jq --compact-output . "$root/body") == "{\"user\":\"admin\",\"password\":\"$(password syncthing)\"}" ]] ||
  fail "sent $(cat "$root/body")"

begin "Syncthing, config.xml not written yet: waits for the API key"
# Written by the second look.
syncthing '[[ $2 != *apikey* ]] || if [[ -e $root/written ]]; then echo the-api-key; else touch "$root/written"; fi'
expect_status 0
expect_called "sleep 1"
expect_file header "X-API-Key: the-api-key"

begin "Syncthing, a GUI login of its own: left alone, with no login kept"
syncthing 'case $2 in *apikey*) echo the-api-key ;; *user*) echo charles ;; esac'
expect_status 0
expect_missing credstore/syncthing-admin
expect_not_called curl
expect_output "syncthing has a login already; leaving it"

# --- NZBHydra2

nzbhydra2() {
  start nzbhydra2 config="$root/nzbhydra.yml" base="$base"
}

# expect_login <password>: nzbhydra.yml has a form login for admin alone, with
# that password bcrypted, and every part of the UI restricted.
expect_login() {
  local config=$root/nzbhydra.yml hash
  [[ $(yq --output-format=json --indent=0 '.auth | del(.users, .authHeader, .authHeaderIpRanges, .rememberUsers, .rememberMeValidityDays, .allowApiStats)' "$config") == \
    '{"authType":"FORM","restrictAdmin":true,"restrictDetailsDl":true,"restrictIndexerSelection":true,"restrictSearch":true,"restrictStats":true}' ]] ||
    fail "auth is $(yq --output-format=json --indent=0 .auth "$config")"
  [[ $(yq --output-format=json --indent=0 '.auth.users[] | del(.password)' "$config") == \
    '{"username":"admin","maySeeAdmin":true,"maySeeDetailsDl":true,"maySeeStats":true,"showIndexerSelection":true}' ]] ||
    fail "users are $(yq --output-format=json --indent=0 .auth.users "$config")"
  hash=$(yq '.auth.users[0].password' "$config")
  [[ $hash =~ ^\{bcrypt\}\$2b\$10\$[./0-9A-Za-z]{53}$ ]] || fail "password is '$hash', not {bcrypt} and a bcrypt hash"
  hash=${hash#\{bcrypt\}}
  [[ $(printf '%s\n' "$1" | mkpasswd --method=bcrypt --rounds=10 --salt="${hash:7:22}" --stdin) == "$hash" ]] ||
    fail "the hash isn't of '$1'"
}

begin "NZBHydra2, no nzbhydra.yml yet: its base config, with a form login for admin and the kept password"
nzbhydra2
expect_status 0
expect_kept nzbhydra2
expect_login "$(password nzbhydra2)"
[[ $(yq 'del(.auth)' "$root/nzbhydra.yml") == "$(yq 'del(.auth)' "$base")" ]] ||
  fail "the rest of the base config changed"
[[ $(stat -c %a "$root/nzbhydra.yml") == 600 ]] || fail "nzbhydra.yml is readable by others"

begin "NZBHydra2, nzbhydra.yml with no login, as NZBHydra2 writes it: the login is added, the rest kept"
yq '.main.apiKey = "the-api-key"' "$base" >"$root/nzbhydra.yml"
nzbhydra2
expect_status 0
expect_kept nzbhydra2
expect_login "$(password nzbhydra2)"
[[ $(yq .main.apiKey "$root/nzbhydra.yml") == the-api-key ]] || fail "the API key went"

begin "NZBHydra2, a login of its own: left alone, with no login kept"
yq '.auth.authType = "BASIC" | .auth.users = [{"username": "charles", "password": "{bcrypt}theirs"}]' "$base" >"$root/nzbhydra.yml"
cp "$root/nzbhydra.yml" "$root/before.yml"
nzbhydra2
expect_status 0
cmp -s "$root/nzbhydra.yml" "$root/before.yml" || fail "nzbhydra.yml changed"
expect_missing credstore/nzbhydra2-admin
expect_output "nzbhydra2 has a login already; leaving it"

begin "NZBHydra2, users with auth switched off in the web UI: left alone"
yq '.auth.users = [{"username": "charles", "password": "{bcrypt}theirs"}]' "$base" >"$root/nzbhydra.yml"
cp "$root/nzbhydra.yml" "$root/before.yml"
nzbhydra2
expect_status 0
cmp -s "$root/nzbhydra.yml" "$root/before.yml" || fail "nzbhydra.yml changed"
expect_missing credstore/nzbhydra2-admin

finish
