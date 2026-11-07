mkdir -p "$state"
healthy=0
if systemctl is-active --quiet smoke-test.service; then healthy=1; fi

if [[ ! -f $state/pending ]]; then
  if ((healthy)); then exit 0; fi
  # Never roll back past a system that has already been confirmed; that only
  # trades one broken state for a reboot loop.
  echo "smoke tests failed with no upgrade pending; leaving the system as it is" >&2
  exit 1
fi

read -r rev new prev <"$state/pending"
booted=$(readlink -f "$booted_system")

if [[ $booted == "$new" ]] && ((healthy)); then
  bootctl set-default ""
  echo "$rev" >"$state/rev"
  rm "$state/pending"
  echo "upgrade to $rev confirmed"
  exit 0
fi

if [[ $booted == "$new" ]]; then
  echo "upgrade to $rev failed its smoke tests; rolling back and rebooting" >&2
  roll_back "$rev" "$prev"
  systemctl reboot
else
  # The one-shot boot didn't make it this far, so we are already on $prev.
  echo "upgrade to $rev never finished booting; rolled back" >&2
  roll_back "$rev" "$prev"
fi
