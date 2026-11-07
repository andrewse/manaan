# Each check is starting, healthy or unhealthy. A starting check is retried
# until its deadline (seconds since the healthchecks started), so services still
# coming up after boot get time; an unhealthy one fails at once. After the
# first failure the remaining checks are only reported, not waited for: the
# outcome is already decided. Followed by one `check` line per check, then
# `report`, by default.nix.

failed=0

# probe <type> <target>: exits 0 if healthy, 1 if starting, 2 if unhealthy.
# Only a unit can tell starting from unhealthy; other probes can't, so a probe
# that doesn't pass yet counts as starting.
probe() {
  local type=$1 target=$2
  case $type in
    tcp) timeout 3 bash -c "exec 3<>/dev/tcp/${target%:*}/${target##*:}" || return 1 ;;
    http) curl --fail --silent --show-error --output /dev/null --max-time 5 "$target" || return 1 ;;
    unit)
      case $(systemctl show --property=ActiveState --value "$target") in
        active) ;;
        failed) return 2 ;;
        *) return 1 ;; # activating, or not started yet
      esac
      ;;
    command) bash -c "$target" || return 1 ;;
  esac
}

# explain <type> <target>: why a check failed.
explain() {
  local type=$1 target=$2
  case $type in
    unit) systemctl status --no-pager --lines=5 "$target" ;;
    *) probe "$type" "$target" ;;
  esac
}

check() {
  local name=$1 type=$2 target=$3 timeout=$4 result reason
  while true; do
    result=0
    probe "$type" "$target" >/dev/null 2>&1 || result=$?
    case $result in
      0)
        echo "ok   $name"
        return 0
        ;;
      2)
        reason="unhealthy"
        break
        ;;
    esac
    if ((failed > 0)); then
      reason="not ready, and not waited for after an earlier failure"
      break
    fi
    if ((SECONDS >= timeout)); then
      reason="still starting after ${timeout}s"
      break
    fi
    sleep 2
  done
  echo "FAIL $name ($type $target): $reason"
  explain "$type" "$target" 2>&1 | sed 's/^/     /' || true
  failed=$((failed + 1))
}

report() {
  if ((failed > 0)); then
    echo "$failed check(s) failed"
    exit 1
  fi
  echo "all checks passed"
}
