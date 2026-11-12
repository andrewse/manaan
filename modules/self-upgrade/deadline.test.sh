# shellcheck shell=bash
# What self-upgrade-deadline does when the trial deadline passes. systemd only
# starts it while `pending` exists (watchdog.test.nix); it may be gone by the
# time the script reads it.

# On PATH; see tests/unit.nix.
source script-harness.sh
# deadline.sh, beside this file.
scripts=$(dirname "$0")

deadline() {
  run "deadline=1620" "$scripts/deadline.sh"
}

# on_trial <booted system>: self-upgrade staged rev1 (new) over old and rebooted, booting <system>.
on_trial() {
  installed "$old"
  "$root/bin/nix-env" --profile "$root/profiles/system" --set "$new"
  ln -sfn "$1" "$root/run/current-system"
  ln -sfn "$1" "$root/run/booted-system"
  echo "rev1 $new $old" >"$root/state/pending"
  : >"$root/calls"
}

begin "booted the new system and still undecided: rebooted, onto the old one"
old=$(system old) new=$(system new)
on_trial "$new"
deadline
expect_status 0
expect_output "upgrade to rev1 still undecided 1620s after boot"
expect_called "systemctl reboot"
expect_not_called bootctl
expect_not_called nix-env
expect_file state/pending "rev1 $new $old"

begin "booted the old system with the upgrade pending: left to verify, no reboot"
old=$(system old) new=$(system new)
on_trial "$old"
deadline
expect_status 0
expect_output "leaving it to self-upgrade-verify"
expect_not_called systemctl
expect_file state/pending "rev1 $new $old"

begin "verify decided after systemd checked for pending: no reboot"
old=$(system old) new=$(system new)
on_trial "$new"
rm "$root/state/pending"
deadline
expect_status 0
expect_not_called systemctl

finish
