# shellcheck shell=bash disable=SC2016 # stub bodies expand in the stub
# Self-upgrade across reboots, one story told case by case: upgrade.sh stages
# a release and asks for a reboot, and verify.sh decides at the next boot. The
# firmware and boot loader are faked, so that what each boot starts follows
# from what the scripts told bootctl and switch-to-configuration; the releases
# are fake systems that come up healthy, come up unhealthy, or panic.
# tests/system/upgrade.nix tells the same story in a VM, against the real
# firmware.
#
#   rollback.test.sh <dir with upgrade.sh, verify.sh and lib.sh>

# On PATH; see tests/script-test.nix.
source script-harness.sh
scripts=$1

# The boot entries are files under $root/firmware: `default` and `oneshot` are
# the variables bootctl set-default and set-oneshot set, and `loader` is the
# entry switch-to-configuration last made the boot loader's own default, which
# is the system profile's current generation.
firmware() {
  mkdir -p "$root/firmware"
  stub "$root/bin/bootctl" bootctl '
case $1 in
  set-default) if [[ -n $2 ]]; then echo "$2" >"$root/firmware/default"; else rm -f "$root/firmware/default"; fi ;;
  set-oneshot) echo "$2" >"$root/firmware/oneshot" ;;
esac'
}

# release <name> [unhealthy|panics]: a fake system that comes up healthy when
# booted, unless it is marked otherwise. Prints its path.
release() {
  local path
  path=$(system "$1" '
[[ $1 == boot ]] || exit 0
link=$(readlink "$root/profiles/system")
link=${link#system-}
echo "nixos-generation-${link%-link}.conf" >"$root/firmware/loader"')
  [[ -z ${2:-} ]] || touch "$path/$2"
  echo "$path"
}

# fresh_install <system>: the machine was installed with <system>, its first
# generation, and has not booted yet.
fresh_install() {
  installed "$1"
  echo nixos-generation-1.conf >"$root/firmware/loader"
}

# boot: the firmware boots the one-shot entry if there is one, clearing it,
# then its default, then the boot loader's. A system that panics reboots at
# once. One that comes up runs verify, as self-upgrade-verify.service does once
# the healthchecks are done. Each boot's system is logged to $root/boots.
boot() {
  local entry generation system tries=0
  while :; do
    if [[ -s $root/firmware/oneshot ]]; then
      entry=$(<"$root/firmware/oneshot")
      rm "$root/firmware/oneshot"
    elif [[ -s $root/firmware/default ]]; then
      entry=$(<"$root/firmware/default")
    else
      entry=$(<"$root/firmware/loader")
    fi
    generation=${entry#nixos-generation-}
    system=$(readlink -f "$root/profiles/system-${generation%.conf}-link")
    basename "$system" >>"$root/boots"
    [[ -e $system/panics ]] || break
    tries=$((tries + 1))
    ((tries < 3)) || {
      fail "no boot came up"
      return
    }
  done
  ln -sfn "$system" "$root/run/booted-system"
  ln -sfn "$system" "$root/run/current-system"
  if [[ -e $system/unhealthy ]]; then rm -f "$root/healthy"; else touch "$root/healthy"; fi
  : >"$root/calls"
  run "" "$scripts/lib.sh" "$scripts/verify.sh"
}

# As in upgrade.test.sh, the release branch is a local repo whose commits name
# a system instead of building one.
build=$(
  cat <<'EOF'
build_system() {
  git -C "$url" show "$1:system"
}
EOF
)
upgrade() {
  : >"$root/calls"
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

# expect_boots <name>...: the systems booted since the case began, in order.
expect_boots() {
  local booted
  booted=$(tr '\n' ' ' <"$root/boots")
  [[ $booted == "$* " ]] || fail "booted: ${booted% }, expected: $*"
}

# expect_kept <name> <rev>: running <name> as the confirmed release <rev>, with
# nothing on trial.
expect_kept() {
  local booted
  booted=$(basename "$(readlink -f "$root/run/booted-system")")
  [[ $booted == "$1" ]] || fail "running $booted, expected $1"
  [[ $(basename "$(readlink -f "$root/profiles/system")") == "$1" ]] || fail "the profile isn't $1"
  expect_file state/rev "$2"
  expect_missing state/pending
}

expect_bad() {
  grep -qxF "$1" "$root/state/bad-revs" || fail "$1 is not in bad-revs"
}

begin "a good release: booted once on trial, confirmed, and kept across a reboot"
firmware
fresh_install "$(release installed)"
boot
expect_status 0
good=$(publish "$(release good)")
upgrade
expect_output "rebooting into $good"
expect_called "systemctl reboot"
boot
expect_output "upgrade to $good confirmed"
expect_not_called "systemctl reboot"
boot
expect_boots installed good good
expect_kept good "$good"

carry_on "a release that fails its healthchecks: rolled back, rebooted onto the kept release, and marked bad"
: >"$root/boots"
failing=$(publish "$(release failing unhealthy)")
upgrade
expect_called "systemctl reboot"
boot
expect_output "upgrade to $failing failed its healthchecks"
expect_called "systemctl reboot"
boot
expect_status 0
expect_boots failing good
expect_kept good "$good"
expect_bad "$failing"

carry_on "a release that cannot boot: the firmware falls back to the kept release, which rolls it back"
: >"$root/boots"
unbootable=$(publish "$(release unbootable panics)")
upgrade
expect_called "systemctl reboot"
boot
expect_output "upgrade to $unbootable never finished booting"
expect_not_called "systemctl reboot"
expect_boots unbootable good
expect_kept good "$good"
expect_bad "$unbootable"

carry_on "a release that failed is not tried again"
upgrade
expect_status 0
expect_output "$unbootable failed before"
expect_not_called nix-env
expect_not_called bootctl
expect_not_called "systemctl reboot"
expect_missing state/pending

carry_on "after the failed upgrades, the kept release keeps booting"
: >"$root/boots"
boot
boot
expect_boots good good
expect_kept good "$good"

finish
