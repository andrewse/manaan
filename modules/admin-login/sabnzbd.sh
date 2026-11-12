# SABnzbd's part of generate.sh and login.sh, which run before the NixOS
# module's preStart. login.sh writes $out, which that preStart merges over
# sabnzbd.ini as one of its secretFiles: the login while there is none,
# otherwise nothing, since the module needs the file either way. Prepended by
# default.nix with ini= and out=.

# misc <key>: the key's value in sabnzbd.ini's [misc] section, unquoted;
# empty if it, or the file, isn't there.
misc() {
  [[ -e $ini ]] || return 0
  awk -v key="$1" '
    /^[ \t]*\[/ { in_misc = $0 ~ /^[ \t]*\[misc\][ \t]*$/; next }
    in_misc && match($0, "^[ \t]*" key "[ \t]*=") {
      value = substr($0, RLENGTH + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
      print value
      exit
    }' "$ini"
}

has_login() {
  [[ -n $(misc username) || -n $(misc password) ]]
}

set_login() {
  local hex i byte
  # Kept unquoted in the ini, so nothing ConfigObj would read as a list,
  # a quote or a comment.
  if [[ ! $username =~ ^[A-Za-z0-9._@+-]+$ ]]; then
    echo "SABnzbd's username may only have letters, digits and . _ @ + -" >&2
    exit 1
  fi
  # SABnzbd's own encoding, which it reads whatever the password holds:
  # !!!encoded!!! and each character as two hex digits. Only ASCII
  # characters are one byte, so two digits, in it.
  hex=$(printf %s "$password" | od -An -v -tx1 | tr -d ' \n')
  for ((i = 0; i < ${#hex}; i += 2)); do
    byte=$((16#${hex:i:2}))
    if ((byte < 0x20 || byte > 0x7e)); then
      echo "SABnzbd's password may only have printable ASCII characters" >&2
      exit 1
    fi
  done
  printf '[misc]\nusername = %s\npassword = !!!encoded!!!%s\n' "$username" "$hex" >"$out"
  echo "SABnzbd's login is $username"
}

no_login() {
  : >"$out"
}
