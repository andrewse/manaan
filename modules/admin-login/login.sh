# Run as the service's user, in its sandbox, after the service's own script,
# which defines has_login, set_login and no_login. While the service has no
# login, gives it the one generate.sh kept, which systemd hands the unit as
# the credential $credential (ImportCredential=): `username=` and `password=`
# lines. The credential is there whenever the file is, so this checks for a
# login itself, and sets nothing once the service has one. Prepended by
# default.nix with credential= and the service's own variables.

umask 077
login=$CREDENTIALS_DIRECTORY/$credential

if has_login; then
  no_login
elif [[ ! -e $login ]]; then
  echo "no login kept for the service to be given" >&2
  no_login
else
  username=
  password=
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    case $line in
    username=*) username=${line#username=} ;;
    password=*) password=${line#password=} ;;
    esac
  done <"$login"
  if [[ -z $username || -z $password ]]; then
    echo "the login needs a username= line and a password= line" >&2
    exit 1
  fi
  set_login
fi
