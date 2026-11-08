# `<name> <command>` for one service: its logs through journalctl, its unit
# through systemctl. Prepended by default.nix with name=, unit= (empty for
# none), journal=(journalctl options selecting its entries) and passthrough=
# (the program of the same name anything else is handed to; empty for none).

usage() {
  local commands="logs|follow|errors"
  [[ -z $unit ]] || commands="status|$commands|start|stop|restart"
  echo "usage: $name {$commands|help} [options for journalctl or systemctl]"
  echo
  echo "  logs     its journal, from the end; e.g. $name logs --since today"
  echo "  follow   new journal entries as they arrive"
  echo "  errors   warnings and worse since boot"
  if [[ -n $unit ]]; then
    echo "  status   systemctl status $unit"
    echo "  start, stop, restart"
    echo "           systemctl <command> $unit, through sudo unless root"
  fi
  [[ -z $passthrough ]] || echo "  anything else is handed to $passthrough"
}

# The unit commands: there is nothing to act on without a unit.
need_unit() {
  [[ -n $unit ]] && return
  echo "$name has no systemd unit of its own; it has only logs, follow and errors" >&2
  exit 2
}

command=${1:-}
(($#)) && shift

case $command in
  logs) exec journalctl "${journal[@]}" --pager-end "$@" ;;
  follow) exec journalctl "${journal[@]}" --follow "$@" ;;
  errors) exec journalctl "${journal[@]}" --boot --priority=warning "$@" ;;
  status)
    need_unit
    exec systemctl status "$unit" "$@"
    ;;
  start | stop | restart)
    need_unit
    if ((EUID == 0)); then
      exec systemctl "$command" "$unit" "$@"
    fi
    exec sudo systemctl "$command" "$unit" "$@"
    ;;
  help) usage ;;
  *)
    [[ -z $passthrough || -z $command ]] || exec "$passthrough" "$command" "$@"
    usage >&2
    exit 2
    ;;
esac
