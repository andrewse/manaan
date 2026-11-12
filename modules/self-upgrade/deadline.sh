# What self-upgrade-deadline does once the trial deadline has passed and an
# upgrade is still pending: the boot it was on hung somewhere short of
# self-upgrade-verify deciding it, so reboot. The one-shot entry was used up
# booting it, so that lands on the previous system, whose verify rolls it back.

# verify may have decided it since systemd checked for the file.
read -r rev new _ 2>/dev/null <"$state/pending" || exit 0
booted=$(readlink -f "$booted_system")

# Only the trial boot itself is rebooted. Pending on the previous system means
# that boot is on its way to verify rolling the upgrade back, and rebooting a
# slow or hung previous system would only loop on it.
if [[ $booted != "$new" ]]; then
  echo "upgrade to $rev is pending but not booted; leaving it to self-upgrade-verify"
  exit 0
fi

echo "upgrade to $rev still undecided ${deadline}s after boot; rebooting onto the previous system" >&2
systemctl reboot
