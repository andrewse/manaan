# Shared by upgrade.sh and verify.sh.

# Number of the generation the system profile currently points at.
generation() {
  local link
  link=$(readlink "$profile")
  link=${link#system-}
  echo "${link%-link}"
}

# failures <rev>: how many attempts at <rev> have failed.
failures() {
  grep -cxF "$1" "$state/bad-revs" || true
}

# roll_back <rev> <system>: record a failed attempt at <rev> and make <system>
# the default boot again.
roll_back() {
  echo "$1" >>"$state/bad-revs"
  nix-env --profile "$profile" --set "$2"
  "$2/bin/switch-to-configuration" boot
  bootctl set-default ""
  rm -f "$state/pending"
  local failed
  failed=$(failures "$1")
  if ((failed < attempts)); then
    echo "$1 failed attempt $failed of $attempts; it will be tried again" >&2
  else
    echo "$1 failed $failed times; skipping it until the branch moves" >&2
  fi
}

