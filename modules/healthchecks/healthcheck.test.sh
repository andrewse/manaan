# shellcheck shell=bash disable=SC2016 # stub bodies expand in the stub
# How the healthchecks treat a check that is healthy, starting or unhealthy.

# On PATH; see tests/unit.nix.
source script-harness.sh
# healthcheck.sh, beside this file.
scripts=$(dirname "$0")

# states <unit state>...: what `systemctl show` reports for the unit, one
# state per call; the last one repeats.
states() {
  printf '%s\n' "$@" >"$root/states"
  stub "$root/bin/systemctl" systemctl '
case $1 in
  show)
    head -n1 "$root/states"
    (($(wc -l <"$root/states") > 1)) && sed -i 1d "$root/states"
    ;;
esac
exit 0'
  stub "$root/bin/sleep" sleep
}

# healthcheck <check lines>: runs the healthchecks with these checks.
healthcheck() {
  printf '%s\nreport\n' "$1" >"$root/checks"
  run "" "$scripts/healthcheck.sh" "$root/checks"
}

begin "a unit that becomes active after starting: passes"
states activating activating active
healthcheck "check app unit app.service 600"
expect_status 0
expect_output "ok   app"
expect_called "sleep 2"

begin "a unit that has failed: fails without waiting"
states failed
healthcheck "check app unit app.service 600"
expect_failure
expect_output "FAIL app (unit app.service): unhealthy"
expect_not_called sleep

begin "a unit still starting at its deadline: fails"
states activating
healthcheck "check app unit app.service 0"
expect_failure
expect_output "FAIL app (unit app.service): still starting after 0s"

begin "after a failure, later checks are reported but not waited for"
states failed activating
healthcheck "check first unit first.service 600
check second unit second.service 600"
expect_failure
expect_output "FAIL second (unit second.service): not ready, and not waited for after an earlier failure"
expect_output "2 check(s) failed"
expect_not_called sleep

begin "a command that hangs: killed after its few seconds, and reported"
# The real timeout, given one second rather than ten. Were the probe to wait
# on the command, it would pass once the sleep ended, half a minute on.
stub "$root/bin/timeout" timeout "exec $(printf %q "$(command -v timeout)") --kill-after=1 1 \"\${@:3}\""
healthcheck "check hung command 'sleep 30' 0"
expect_failure
expect_output "FAIL hung (command sleep 30): still starting after 0s"
expect_called "timeout --kill-after=2 10 bash -c sleep\\ 30"

finish
