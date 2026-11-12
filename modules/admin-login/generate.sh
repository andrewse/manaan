# Run as root, in <service>-admin-login-generate.service, after the service's
# own script, which defines has_login. While the service has no login and
# none is kept in $file, makes one there: `admin` and 32 random letters and
# digits, readable by root alone. A service with a login of its own gets none,
# so $file only ever holds a login this made; one whose state has gone keeps
# the one already there, which login.sh sets again. Prepended by default.nix
# with service= (its name), file= (in /etc/credstore) and the service's own
# variables.

umask 077

if has_login; then
  echo "$service has a login already; leaving it"
elif [[ -e $file ]]; then
  echo "$service has no login; the one kept in $file will be set again"
else
  install -d -m 700 "${file%/*}"
  password=$(LC_ALL=C tr -dc A-Za-z0-9 < <(head -c 1024 /dev/urandom))
  password=${password:0:32}
  if ((${#password} != 32)); then
    echo "too few random letters and digits for a password" >&2
    exit 1
  fi
  username="admin"
  printf 'username=%s\npassword=%s\n' "$username" "$password" >"$file.new"
  mv "$file.new" "$file"
  echo "made a login for $service in $file"
fi
