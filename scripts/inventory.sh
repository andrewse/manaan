#!/usr/bin/env bash
# Dump what the existing (Ubuntu) manaan runs, so it can be replicated here.
#
#   scripts/fetch-inventory.sh manaan    (from this repo; unpacks into inventory/)
#   sudo bash inventory.sh               (on the machine; writes /tmp/inventory-*.tar.gz)
#
# Read-only: it only runs list/show/inspect commands and copies files.
# Nothing is redacted by default: the dump holds whatever passwords, tokens and
# keys the copied files and docker output contain, so never commit it (this
# repo is public; inventory/ is gitignored). Pass --redact to replace values
# that look like secrets (passwords, tokens, keys, URL credentials, private key
# blocks) with <REDACTED> in copied files and docker output. That is a best
# effort: read the dump before committing any of it.
set -uo pipefail

redact=0
[[ ${1:-} == --redact ]] && redact=1
max_size=$((512 * 1024)) # skip copying files bigger than this

[[ $EUID -eq 0 ]] || {
  echo "run as root: sudo bash $0" >&2
  exit 1
}

host=$(hostname -s)
out=/tmp/inventory-$host-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
chmod 700 "$out"
cd "$out" || exit 1

have() { command -v "$1" >/dev/null 2>&1; }

secret_words='pass|secret|token|psk|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth[_-]?key|client[_-]?secret'

scrub() {
  if ((redact)); then
    sed -E \
      -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\<REDACTED PRIVATE KEY>' \
      -e "s/^([[:space:]]*(-[[:space:]]*)?(export[[:space:]]+)?[\"']?[A-Za-z0-9_.-]*($secret_words)[A-Za-z0-9_.-]*[\"']?[[:space:]]*[:=][[:space:]]*).+$/\1<REDACTED>/I" \
      -e "s/(\"[^\"]*($secret_words)[^\"]*\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"/\1\"<REDACTED>\"/gI" \
      -e "s/(\b[A-Za-z0-9_.-]*($secret_words)[A-Za-z0-9_.-]*=)[^[:space:]\"']+/\1<REDACTED>/gI" \
      -e 's/("auth"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"<REDACTED>"/g' \
      -e 's#(://[^:/@[:space:]]+:)[^@/[:space:]]+@#\1<REDACTED>@#g'
  else
    cat
  fi
}

# run FILE CMD...: record a command and its output (and errors) in FILE.
# Gives up after $limit seconds (default 300), killing it if it ignores TERM.
run() {
  local file=$1
  shift
  mkdir -p "$(dirname "$file")"
  echo "  \$ $*"
  {
    echo "\$ $*"
    timeout -k 10 "${limit:-300}" "$@" 2>&1 </dev/null
    local rc=$?
    ((rc == 0)) || echo "(exit $rc)"
  } >>"$file"
}

# sh FILE SCRIPT: like run, for pipelines.
sh_run() { run "$1" bash -c "$2"; }

# grab PATH...: copy files under files/, scrubbed. Directories are copied
# recursively. Binary, oversized and private-key files are listed, not copied.
grab() {
  local src dst
  for src in "$@"; do
    if [[ -L $src ]]; then
      echo "$src -> $(readlink "$src")" >>files/SYMLINKS
    elif [[ -d $src ]]; then
      while IFS= read -r -d '' f; do grab "$f"; done < <(find "$src" -mindepth 1 -maxdepth 1 -print0)
    elif [[ -f $src ]]; then
      dst=files$src
      case $src in
        /etc/shadow* | /etc/gshadow* | */ssh_host_*_key | */.ssh/id_* | /etc/ssl/private/*)
          [[ $src == *.pub ]] || {
            echo "$src (sensitive)" >>files/SKIPPED
            continue
          }
          ;;
      esac
      if (($(stat -c %s "$src") > max_size)); then
        echo "$src ($(stat -c %s "$src") bytes)" >>files/SKIPPED
      elif [[ -s $src ]] && ! grep -Iq . "$src"; then
        echo "$src (binary)" >>files/SKIPPED
      else
        mkdir -p "$(dirname "$dst")"
        scrub <"$src" >"$dst"
        touch -r "$src" "$dst"
      fi
    fi
  done
}

mkdir -p files
echo "collecting into $out"

echo "- system"
run system/os.txt cat /etc/os-release
run system/os.txt uname -a
run system/os.txt uptime
run system/os.txt hostnamectl
run system/os.txt timedatectl
run system/os.txt localectl
run system/cmdline.txt cat /proc/cmdline
run system/hardware.txt lscpu
run system/hardware.txt free -h
have dmidecode && run system/hardware.txt dmidecode -t system
run system/lsmod.txt lsmod
grab /etc/hostname /etc/hosts /etc/timezone /etc/sysctl.conf /etc/sysctl.d /etc/modules /etc/modules-load.d /etc/modprobe.d

echo "- storage"
grab /etc/fstab /etc/crypttab /etc/exports /etc/auto.master /etc/auto.master.d
run storage/lsblk.txt lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL
run storage/blkid.txt blkid
run storage/findmnt.txt findmnt -A
# Local filesystems only: df blocks for good on a dead network mount, and
# findmnt above already lists those.
run storage/df.txt df -hTl
run storage/swap.txt swapon --show
have pvs && run storage/lvm.txt pvs && run storage/lvm.txt vgs && run storage/lvm.txt lvs -a
have zpool && run storage/zfs.txt zpool status && run storage/zfs.txt zfs list -o name,used,avail,mountpoint
[[ -r /proc/mdstat ]] && run storage/mdstat.txt cat /proc/mdstat
# du walks every file, so it is the slow part: walk / once (which covers
# /var/lib, /srv, /opt...), then only the data dirs that are filesystems of
# their own (and not network mounts, which can block). du prints each
# directory as it finishes, so a timeout keeps what it got so far.
limit=120 run storage/du.txt du -xhd2 /
for d in /srv /opt /data /mnt /media; do
  findmnt -n --mountpoint "$d" -t nonfs,nfs4,cifs,smb3,fuse.sshfs >/dev/null && limit=120 run storage/du-other.txt du -xhd2 "$d"
done

echo "- network"
run network/ip.txt ip -br addr
run network/ip.txt ip addr
run network/ip.txt ip route
run network/ip.txt ip -6 route
run network/listening.txt ss -tulpn
have resolvectl && run network/dns.txt resolvectl status
grab /etc/resolv.conf /etc/netplan /etc/network/interfaces /etc/network/interfaces.d /etc/systemd/network /etc/NetworkManager/system-connections
have ufw && run network/firewall.txt ufw status verbose
have iptables-save && run network/firewall.txt iptables-save
have ip6tables-save && run network/firewall.txt ip6tables-save
have nft && run network/firewall.txt nft list ruleset
if have tailscale; then
  run network/tailscale.txt tailscale version
  run network/tailscale.txt tailscale status
  run network/tailscale.txt tailscale ip
  run network/tailscale.txt tailscale debug prefs
fi

echo "- users"
sh_run users/users.txt "getent passwd | awk -F: '\$3 == 0 || \$3 >= 1000'"
sh_run users/groups.txt "getent group | awk -F: '\$4 != \"\"'"
run users/password-status.txt passwd -S -a
have lastlog && run users/logins.txt lastlog
grab /etc/sudoers /etc/sudoers.d
for home in /root /home/*; do
  [[ -d $home/.ssh ]] && grab "$home/.ssh"
done

echo "- ssh"
run ssh/sshd-effective.txt sshd -T
grab /etc/ssh

echo "- packages"
run packages/manual.txt apt-mark showmanual
run packages/dpkg.txt dpkg -l
run packages/held.txt apt-mark showhold
grab /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/preferences.d /etc/apt/apt.conf.d
have snap && run packages/snap.txt snap list
have flatpak && run packages/flatpak.txt flatpak list
have pip3 && run packages/pip.txt pip3 list
have npm && run packages/npm.txt npm -g ls --depth=0
run packages/usr-local.txt find /usr/local -xdev -not -path '*/share/*' -type f -ls
run packages/opt.txt find /opt -xdev -maxdepth 3 -ls
grab /usr/local/bin /usr/local/sbin

echo "- systemd"
run systemd/running.txt systemctl list-units --type=service --state=running --no-pager
run systemd/units.txt systemctl list-units --all --no-pager
run systemd/enabled.txt systemctl list-unit-files --state=enabled --no-pager
run systemd/failed.txt systemctl --failed --no-pager
run systemd/timers.txt systemctl list-timers --all --no-pager
run systemd/sockets.txt systemctl list-sockets --all --no-pager
run systemd/mounts.txt systemctl list-units --type=mount,automount,swap --all --no-pager
run systemd/linger.txt ls /var/lib/systemd/linger
mkdir -p systemd/cat
{
  systemctl list-units --type=service,timer,socket,mount,path --state=running,listening,waiting --no-legend --plain | awk '{print $1}'
  systemctl list-unit-files --state=enabled --no-legend | awk '{print $1}'
} | sort -u | while read -r unit; do
  systemctl cat "$unit" >"systemd/cat/$unit" 2>&1
done
grab /etc/systemd /usr/local/lib/systemd /etc/tmpfiles.d
for home in /root /home/*; do
  [[ -d $home/.config/systemd ]] && grab "$home/.config/systemd"
done

echo "- cron"
grab /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/anacrontab /var/spool/cron/crontabs
have atq && run cron/at.txt atq

echo "- /etc changed from package defaults"
# Config files the packages ship, whose contents were edited.
dpkg-query -W -f='${Conffiles}\n' 2>/dev/null |
  awk 'NF == 2 {print $2 "  " $1}' |
  md5sum -c 2>/dev/null | sed -n 's/: FAILED$//p' | sort -u >etc-changed.txt
# Files in /etc that no package owns: added by hand or by scripts.
sort -u /var/lib/dpkg/info/*.list >/tmp/.inventory-owned
find /etc -xdev \( -type f -o -type l \) | sort |
  comm -23 - /tmp/.inventory-owned |
  grep -vE '^/etc/(ssl/certs/|alternatives/|rc[0-6S]\.d/|systemd/system/.*\.wants/|ld\.so\.cache$|\.pwd\.lock$|.*-$|apparmor\.d/cache/)' >etc-unowned.txt
rm -f /tmp/.inventory-owned
while read -r f; do grab "$f"; done < <(cat etc-changed.txt etc-unowned.txt)

echo "- root's home"
run home/root-listing.txt find /root -xdev -not -path '/root/.cache/*' -ls
for home in /home/*; do
  [[ -d $home ]] && run "home/$(basename "$home")-listing.txt" find "$home" -xdev -maxdepth 3 -not -path '*/.cache/*' -ls
done
while IFS= read -r -d '' f; do grab "$f"; done < <(
  find /root -xdev \( -name .cache -o -name node_modules -o -name .npm -o -name .vscode-server -o -name .git -o -path /root/.local/share \) -prune \
    -o -type f -print0
)

if have docker; then
  echo "- docker"
  run docker/version.txt docker version
  run docker/info.txt docker info
  docker compose version >/dev/null 2>&1 && run docker/compose.txt docker compose ls --all
  have docker-compose && run docker/compose.txt docker-compose version
  run docker/ps.txt docker ps -a --no-trunc
  run docker/images.txt docker image ls --digests
  run docker/volumes.txt docker volume ls
  run docker/networks.txt docker network ls
  run docker/plugins.txt docker plugin ls
  run docker/df.txt docker system df -v
  grab /etc/docker /etc/default/docker

  mkdir -p docker/containers docker/volumes docker/networks
  # One line per container: what you need to recreate it at a glance.
  docker ps -aq | while read -r id; do
    name=$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')
    docker inspect "$id" | scrub >"docker/containers/$name.json"
    docker inspect -f '{{.Name}}
  image:   {{.Config.Image}}
  state:   {{.State.Status}} (restart: {{.HostConfig.RestartPolicy.Name}})
  compose: {{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.project.working_dir"}}
  network: {{.HostConfig.NetworkMode}}{{range $k, $v := .NetworkSettings.Networks}} {{$k}}{{end}}
  ports:  {{range $p, $b := .HostConfig.PortBindings}} {{range $b}}{{.HostIp}}:{{.HostPort}}{{end}}->{{$p}}{{end}}
  mounts:{{range .Mounts}}
    {{.Type}} {{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}} -> {{.Destination}}{{if not .RW}} (ro){{end}}{{end}}
' "$id" >>docker/summary.txt
  done
  docker volume ls -q | while read -r v; do
    docker volume inspect "$v" | scrub >"docker/volumes/$v.json"
  done
  docker network ls -q | while read -r n; do
    name=$(docker network inspect -f '{{.Name}}' "$n")
    docker network inspect "$n" | scrub >"docker/networks/$name.json"
  done
  # Size of every bind-mount source and named volume.
  docker ps -aq | xargs -r docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' |
    sort -u | grep . | while read -r src; do
    run docker/mount-sizes.txt du -sh "$src"
  done

  # Compose projects: copy their files and render the effective config.
  docker ps -aq | xargs -r docker inspect -f \
    '{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}' |
    sort -u | while IFS='|' read -r dir files; do
    [[ -n $dir ]] || continue
    while IFS= read -r -d '' f; do grab "$f"; done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
    args=()
    IFS=, read -ra cfs <<<"$files"
    for cf in "${cfs[@]}"; do
      grab "$cf"
      args+=(-f "$cf")
    done
    if docker compose version >/dev/null 2>&1 && ((${#args[@]})); then
      (cd "$dir" && docker compose "${args[@]}" config 2>&1 </dev/null) | scrub >"docker/compose-$(basename "$dir").rendered.yml"
    fi
  done
  run docker/compose-files-found.txt find / -xdev -maxdepth 5 -path /var/lib/docker -prune -o \
    -type f \( -name 'docker-compose*.y*ml' -o -name 'compose*.y*ml' \) -print
fi

cat >README.md <<EOF
# Inventory of $host

Taken $(date -Iseconds) by scripts/inventory.sh (redaction: $( ((redact)) && echo on || echo off)).

- system/, storage/, network/, users/, ssh/, packages/, systemd/, cron/, docker/, home/: command output
- systemd/cat/: \`systemctl cat\` of every running or enabled unit
- docker/summary.txt: one entry per container; docker/containers/: full \`docker inspect\`
- etc-changed.txt: package config files edited from their defaults
- etc-unowned.txt: files in /etc that no package installed
- files/: copies of the files above, plus fstab, cron, sudoers, root's home, compose projects...
- files/SKIPPED: files not copied (binary, too big, private keys); files/SYMLINKS: symlink targets
EOF

cd /tmp || exit 1
tar -czf "$out.tar.gz" "$(basename "$out")"
chmod 600 "$out.tar.gz"
echo
echo "done: $out.tar.gz ($(du -h "$out.tar.gz" | cut -f1))"
if ((redact)); then
  echo "it may still hold secrets: check it before committing anything from it"
else
  echo "it holds secrets unredacted: do not commit anything from it"
fi
