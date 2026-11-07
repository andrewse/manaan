# shellcheck shell=bash
# What self-upgrade does when the release branch moves.

# On PATH; see tests/scripts.nix.
source script-harness.sh
# upgrade.sh, beside this file.
scripts=$(dirname "$0")

# As in the lifecycle test, the release branch is a local repo whose commits
# name a system instead of building one.
build=$(
  cat <<'EOF'
build_system() {
  echo "build $1" >>"$root/calls"
  git -C "$url" show "$1:system"
}
EOF
)
upgrade() {
  run "url=$(printf %q "$root/release") branch=release"$'\n'"$build" "$scripts/lib.sh" "$scripts/upgrade.sh"
}

# publish <system>: commits <system> to the release branch. Prints the commit.
publish() {
  [[ -d $root/release ]] || git init -q -b release "$root/release"
  echo "$1" >"$root/release/system"
  git -C "$root/release" add system
  git -C "$root/release" -c user.name=ci -c user.email=ci@localhost commit -q -m "$1"
  git -C "$root/release" rev-parse HEAD
}

begin "a new release: boots it once, keeping the running system the default"
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
