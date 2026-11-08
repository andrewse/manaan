# shellcheck shell=bash disable=SC2016 # stub bodies expand in the stub
# Shared by the script tests. Each case runs a script from the repo against a
# fresh fake root: the paths it reads and writes are moved under $root, and the
# commands that would change the machine are stubs that log each call, with
# its arguments quoted, to $root/calls.

set -o errexit -o nounset -o pipefail

failures=0
export root

# begin <description>: starts a case in a fresh root.
begin() {
  report
  description=$1
  case_failed=0
  output=
  root=$(mktemp -d)
  mkdir -p "$root/bin" "$root/state" "$root/profiles" "$root/run" "$root/systems"
  touch "$root/calls"
  stub "$root/bin/bootctl" bootctl
  stub "$root/bin/udevadm" udevadm
  # Healthy while $root/healthy exists.
  stub "$root/bin/systemctl" systemctl '[[ $1 != is-active ]] || [[ -e $root/healthy ]]'
  # Adds a generation the way nix-env does: system -> system-N-link -> the system.
  stub "$root/bin/nix-env" nix-env '
[[ $1 == --profile && $3 == --set ]] || exit 1
n=1
while [[ -L $2-$n-link ]]; do n=$((n + 1)); done
ln -s "$4" "$2-$n-link"
ln -sfn "${2##*/}-$n-link" "$2"'
}

# carry_on <description>: starts a case in the last case's root, for a story
# told across several cases.
carry_on() {
  report
  description=$1
  case_failed=0
  output=
}

# stub <path> <name> [shell commands]: an executable that logs `<name> <args>`,
# then runs the commands.
stub() {
  {
    echo "#!$BASH"
    echo "name=$(printf %q "$2")"
    echo '{ printf %s "$name"; (($#)) && printf " %q" "$@"; echo; } >>"$root/calls"'
    echo "${3:-}"
  } >"$1"
  chmod +x "$1"
}

# system <name> [shell commands]: a fake system whose switch-to-configuration
# logs as `<name>/switch-to-configuration`, then runs the commands. Prints its path.
system() {
  mkdir -p "$root/systems/$1/bin"
  stub "$root/systems/$1/bin/switch-to-configuration" "$1/switch-to-configuration" "${2:-}"
  echo "$root/systems/$1"
}

# installed <system>: the machine is running <system>, its only generation.
installed() {
  "$root/bin/nix-env" --profile "$root/profiles/system" --set "$1"
  ln -sfn "$1" "$root/run/current-system"
  ln -sfn "$1" "$root/run/booted-system"
  : >"$root/calls"
}

# run <shell commands> <script>...: runs the scripts as one, the way the Nix
# modules assemble them: the paths under $root, then the commands, then the
# scripts, with the stubs first on PATH. Sets $status and $output.
run() {
  {
    echo 'set -o errexit -o nounset -o pipefail'
    printf '%s=%q\n' \
      state "$root/state" \
      profile "$root/profiles/system" \
      current_system "$root/run/current-system" \
      booted_system "$root/run/booted-system"
    echo "$1"
    shift
    cat "$@"
  } >"$root/script"
  status=0
  output=$(PATH="$root/bin:$PATH" bash "$root/script" 2>&1) || status=$?
}

fail() {
  echo "  $*"
  case_failed=1
}

expect_status() {
  [[ $status == "$1" ]] || fail "exit status $status, expected $1"
}
expect_failure() {
  [[ $status != 0 ]] || fail "exit status 0, expected a failure"
}
expect_output() {
  grep -qF -- "$1" <<<"$output" || fail "output lacks: $1"
}
# expect_called <logged call>, e.g. expect_called "bootctl set-default ''"
expect_called() {
  grep -qxF -- "$1" "$root/calls" || fail "not called: $1"
}
# expect_not_called <command>: no call to the command at all.
expect_not_called() {
  ! grep -q "^$1\( \|$\)" "$root/calls" || fail "called: $(grep "^$1\( \|$\)" "$root/calls" | head -n1)"
}
# expect_file <path under $root> <contents>
expect_file() {
  [[ -f $root/$1 && $(cat "$root/$1") == "$2" ]] ||
    fail "$1 is '$(cat "$root/$1" 2>/dev/null || echo "<missing>")', expected '$2'"
}
expect_missing() {
  [[ ! -e $root/$1 ]] || fail "$1 exists"
}
expect_profile() {
  [[ $(readlink -f "$root/profiles/system") == "$1" ]] ||
    fail "profile is $(readlink -f "$root/profiles/system"), expected $1"
}

# report: prints the result of the case that just ran.
report() {
  [[ -n ${description:-} ]] || return 0
  if ((case_failed)); then
    echo "not ok: $description"
    echo "  output:"
    # shellcheck disable=SC2001
    sed 's/^/    /' <<<"$output"
    echo "  calls:"
    sed 's/^/    /' "$root/calls"
    failures=$((failures + 1))
  else
    echo "ok: $description"
  fi
  description=
}

# finish: ends the last case and fails if any case did.
finish() {
  report
  ((failures == 0)) || {
    echo "$failures failed"
    exit 1
  }
}
