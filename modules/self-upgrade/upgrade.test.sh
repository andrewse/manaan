# shellcheck shell=bash
# What self-upgrade does when the release branch moves.

# On PATH; see tests/unit.nix.
source script-harness.sh
# upgrade.sh, beside this file.
scripts=$(dirname "$0")

# The admins' signing key, a key nobody trusts, and the allowed signers file
# that trusts the first, as default.nix makes it from machine.users.
keys=$(mktemp -d)
for key in admin stranger; do ssh-keygen -q -t ed25519 -N "" -C "$key@test" -f "$keys/$key"; done
echo "admin namespaces=\"git\" $(cat "$keys/admin.pub")" >"$keys/allowed_signers"

# As in the lifecycle test, the release branch is a local repo whose commits
# name a system instead of building one, read from the clone upgrade.sh
# fetched it into.
build=$(
  cat <<'EOF'
build_system() {
  echo "build $1" >>"$root/calls"
  git -C "$clone" show "$1:system"
}
EOF
)
upgrade() {
  run "url=$(printf %q "$root/release") branch=release signers=$(printf %q "$keys/allowed_signers")"$'\n'"$build" \
    "$scripts/lib.sh" "$scripts/upgrade.sh"
}

# publish <system> [admin|stranger|unsigned]: commits <system> to the release
# branch, signed by the admins' key unless told otherwise. Prints the commit.
publish() {
  local sign=(-c gpg.format=ssh -c "user.signingkey=$keys/${2:-admin}" commit -S)
  [[ ${2:-} != unsigned ]] || sign=(commit)
  [[ -d $root/release ]] || git init -q -b release "$root/release"
  echo "$1" >"$root/release/system"
  git -C "$root/release" add system
  git -C "$root/release" -c user.name=ci -c user.email=ci@localhost "${sign[@]}" -q -m "$1"
  git -C "$root/release" rev-parse HEAD
}

# expect_refused <rev>: upgrade.sh refused the branch tip <rev>: nothing built
# or staged, and <rev> not marked bad, as it was never tried.
expect_refused() {
  expect_failure
  expect_output "refusing $1"
  expect_not_called build
  expect_not_called nix-env
  expect_not_called bootctl
  expect_not_called "systemctl reboot"
  expect_missing state/pending
  expect_file state/bad-revs ""
}

begin "a fresh install, with no release deployed yet: boots the signed release once, keeping the running system the default"
old=$(system old) new=$(system new)
installed "$old"
rev=$(publish "$new")
upgrade
expect_status 0
expect_file state/pending "$rev $new $old"
expect_profile "$new"
expect_called "new/switch-to-configuration boot"
expect_called "bootctl set-default nixos-generation-1.conf"
expect_called "bootctl set-oneshot nixos-generation-2.conf"
expect_called "systemctl reboot"
expect_missing state/rev

begin "a signed release that descends from the deployed one: boots it once"
old=$(system old) new=$(system new)
installed "$old"
deployed=$(publish "$old")
echo "$deployed" >"$root/state/rev"
rev=$(publish "$new")
upgrade
expect_status 0
expect_called "build $rev"
expect_file state/pending "$rev $new $old"
expect_called "systemctl reboot"
expect_file state/rev "$deployed"

begin "an unsigned release: refused, and not marked bad"
old=$(system old) new=$(system new)
installed "$old"
rev=$(publish "$new" unsigned)
upgrade
expect_refused "$rev"
expect_output "not signed by a key in"
expect_profile "$old"

begin "a release signed by a key that is not an admin's: refused, and not marked bad"
old=$(system old) new=$(system new)
installed "$old"
rev=$(publish "$new" stranger)
upgrade
expect_refused "$rev"
expect_output "not signed by a key in"
expect_profile "$old"

begin "a signed release older than the deployed one: refused as a downgrade"
old=$(system old) new=$(system new)
installed "$new"
older=$(publish "$old")
deployed=$(publish "$new")
echo "$deployed" >"$root/state/rev"
upgrade
expect_output "already at"
git -C "$root/release" reset -q --hard "$older"
upgrade
expect_refused "$older"
expect_output "does not descend from the deployed $deployed"
expect_profile "$new"

begin "a signed release on a rewritten branch, not descending from the deployed one: refused"
old=$(system old) new=$(system new) other=$(system other)
installed "$new"
base=$(publish "$old")
deployed=$(publish "$new")
echo "$deployed" >"$root/state/rev"
upgrade
expect_output "already at"
git -C "$root/release" reset -q --hard "$base"
rev=$(publish "$other")
upgrade
expect_refused "$rev"
expect_output "does not descend from the deployed $deployed"
expect_profile "$new"

begin "a release that failed before: not tried again"
old=$(system old) new=$(system new)
installed "$old"
rev=$(publish "$new")
echo "$rev" >"$root/state/bad-revs"
upgrade
expect_status 0
expect_output "failed before"
expect_not_called build
expect_not_called nix-env
expect_not_called bootctl
expect_not_called "systemctl reboot"
expect_missing state/pending
expect_profile "$old"

begin "staging the release fails: the running system stays the default, no reboot"
old=$(system old) new=$(system new "exit 1")
installed "$old"
rev=$(publish "$new")
upgrade
expect_failure
expect_output "restoring the running system"
expect_file state/bad-revs "$rev"
expect_missing state/pending
expect_profile "$old"
expect_called "old/switch-to-configuration boot"
expect_called "bootctl set-default ''"
expect_not_called "systemctl reboot"

begin "a release that does not change the system: recorded, no reboot"
old=$(system old)
installed "$old"
rev=$(publish "$old")
upgrade
expect_status 0
expect_file state/rev "$rev"
expect_missing state/pending
expect_not_called nix-env
expect_not_called bootctl
expect_not_called "systemctl reboot"

begin "already at the release: does nothing"
old=$(system old)
installed "$old"
rev=$(publish "$old")
echo "$rev" >"$root/state/rev"
upgrade
expect_status 0
expect_output "already at"
expect_not_called build

finish
