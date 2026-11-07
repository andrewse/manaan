# shellcheck shell=bash
# What self-upgrade-verify does at boot, with and without an upgrade on trial.

# On PATH; see tests/scripts.nix.
source script-harness.sh
# verify.sh, beside this file.
scripts=$(dirname "$0")

verify() {
  run "" "$scripts/lib.sh" "$scripts/verify.sh"
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

begin "booted the new system and it is healthy: confirmed"
old=$(system old) new=$(system new)
on_trial "$new"
touch "$root/healthy"
verify
expect_status 0
expect_file state/rev rev1
expect_missing state/pending
expect_called "bootctl set-default ''"
expect_profile "$new"
expect_not_called nix-env
expect_not_called "systemctl reboot"

begin "booted the new system and its healthchecks fail: rolled back and rebooted"
old=$(system old) new=$(system new)
on_trial "$new"
verify
expect_output "failed its healthchecks"
expect_file state/bad-revs rev1
expect_missing state/rev
expect_missing state/pending
expect_profile "$old"
expect_called "old/switch-to-configuration boot"
expect_called "bootctl set-default ''"
expect_called "systemctl reboot"

begin "booted the old system (the one-shot boot never finished): rolled back, no reboot"
old=$(system old) new=$(system new)
on_trial "$old"
touch "$root/healthy"
verify
expect_status 0
expect_output "never finished booting"
expect_file state/bad-revs rev1
expect_missing state/pending
expect_profile "$old"
expect_called "old/switch-to-configuration boot"
expect_called "bootctl set-default ''"
expect_not_called "systemctl reboot"

begin "nothing pending and healthy: does nothing"
old=$(system old)
installed "$old"
touch "$root/healthy"
verify
expect_status 0
expect_not_called bootctl
expect_not_called nix-env
expect_not_called "systemctl reboot"

begin "nothing pending and unhealthy: fails and does nothing"
old=$(system old)
installed "$old"
verify
expect_failure
expect_output "no upgrade pending"
expect_profile "$old"
expect_not_called bootctl
expect_not_called nix-env
expect_not_called old/switch-to-configuration
expect_not_called "systemctl reboot"

finish
