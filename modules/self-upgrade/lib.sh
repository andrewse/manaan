# Shared by upgrade.sh and verify.sh.

# Number of the generation the system profile currently points at.
generation() {
  local link
  link=$(readlink "$profile")
  link=${link#system-}
  echo "${link%-link}"
}

# roll_back <rev> <system>: mark <rev> bad and make <system> the default boot again.
roll_back() {
  echo "$1" >>"$state/bad-revs"
  nix-env --profile "$profile" --set "$2"
  "$2/bin/switch-to-configuration" boot
  bootctl set-default ""
  rm -f "$state/pending"
}

