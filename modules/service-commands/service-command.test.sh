# shellcheck shell=bash disable=SC2016 # stub bodies expand in the stub
# What each service command runs, for a service with a unit and for one without.

# On PATH; see tests/unit.nix.
source script-harness.sh
# service-command.sh, beside this file.
scripts=$(dirname "$0")

# service <vars> <args>...: runs a service's command with its name, unit and
# journal set by <vars>, the way default.nix sets them. journalctl and sudo are
# stubbed; sudo runs what it is given, so the systemctl stub logs it either way.
service() {
  stub "$root/bin/journalctl" journalctl
  stub "$root/bin/sudo" sudo '"$@"'
  run "$1
set -- ${*:2}" "$scripts/service-command.sh"
}

sonarr="name=sonarr unit=sonarr.service journal=(--unit=sonarr.service) passthrough="
git_server="name=git-server unit= journal=(--identifier=git-server) passthrough="
syncthing="name=syncthing unit=syncthing.service journal=(--unit=syncthing.service) passthrough=\$root/bin/syncthing-real"

begin "logs: the unit's journal from the end, with any options passed on"
service "$sonarr" logs --since today
expect_status 0
expect_called "journalctl --unit=sonarr.service --pager-end --since today"

begin "follow: the unit's new journal entries"
service "$sonarr" follow
expect_called "journalctl --unit=sonarr.service --follow"

begin "errors: warnings and worse since boot"
service "$sonarr" errors
expect_called "journalctl --unit=sonarr.service --boot --priority=warning"

begin "status: systemctl status of the unit"
service "$sonarr" status
expect_called "systemctl status sonarr.service"
expect_not_called sudo

begin "restart: systemctl restart of the unit, through sudo unless root"
service "$sonarr" restart
expect_status 0
expect_called "systemctl restart sonarr.service"

begin "no command: usage on stderr, and a failure"
service "$sonarr"
expect_status 2
expect_output "usage: sonarr {status|logs|follow|errors|start|stop|restart|help}"
expect_not_called journalctl
expect_not_called systemctl

begin "help: usage, and success"
service "$sonarr" help
expect_status 0
expect_output "systemctl <command> sonarr.service"

begin "an unknown command: usage, and a failure"
service "$sonarr" tail
expect_status 2
expect_output "usage: sonarr"

begin "no unit: the journal commands read its journal options"
service "$git_server" logs
expect_called "journalctl --identifier=git-server --pager-end"

begin "no unit: the unit commands are refused"
service "$git_server" restart
expect_status 2
expect_output "git-server has no systemd unit of its own"
expect_not_called systemctl
expect_not_called sudo

begin "no unit: usage lists only the journal commands"
service "$git_server" help
expect_output "usage: git-server {logs|follow|errors|help}"

begin "passthrough: anything but its own commands goes to the real program"
stub "$root/bin/syncthing-real" syncthing-real
service "$syncthing" cli show system
expect_status 0
expect_called "syncthing-real cli show system"
expect_not_called journalctl

begin "passthrough: its own commands are still its own"
stub "$root/bin/syncthing-real" syncthing-real
service "$syncthing" logs
expect_called "journalctl --unit=syncthing.service --pager-end"
expect_not_called syncthing-real

begin "passthrough: no command is usage, not the real program"
stub "$root/bin/syncthing-real" syncthing-real
service "$syncthing"
expect_status 2
expect_output "anything else is handed to $root/bin/syncthing-real"
expect_not_called syncthing-real

finish
