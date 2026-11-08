# machine_configs

NixOS configurations for my machines. Each machine pulls this repo and upgrades
itself; nothing is pushed to machines.

```
push to main ─► CI, `make release`: format, build every host, boot every host in a VM
                 │                   and test it
                 │ pass
                 ▼
               CI fast-forwards `release` ◄─ every Monday, CI, `make update`: update flake.lock;
                 │                           if an input moved and it passes the same checks,
                 │                           push it to main and release it
machine ◄─ self-upgrade.timer: build release, boot it once, healthcheck,
           keep it or roll back
```

## Layout

| Path | What |
| --- | --- |
| `flake.nix`, `flake.lock` | Inputs pinned to exact commits; same commit, same system |
| `ssh/` | Admin users: one file per user, named after them, with their SSH public keys in `authorized_keys` format (also git server access) |
| `hosts/<host>/` | Per-machine config, hardware, disk layout, `host_key.pub`, and the host's own services |
| `modules/system/` | The OS itself, on every host: common settings, users, secrets, the firewall, notifications |
| `modules/healthchecks/` | The checks that gate every upgrade, declared by each module |
| `modules/service-commands/` | A command per service, such as `sonarr logs` or `sonarr restart`, declared by each module |
| `modules/self-upgrade/` | Pulling `release`, booting it once, keeping it or rolling back |
| `modules/services/` | One file (or directory) per app or service, each set up once the host switches it on |
| `lib/` | Functions the modules share, such as `mkScript` for their shell scripts |
| `secrets/` | agenix-encrypted secrets and who can decrypt them |
| `installer/` | Self-installing ISO, one per host |
| `tests/` | Tests run in CI: the harness for the script tests (each script's tests are beside it, as `<name>.test.sh`), and VM tests for every host: the host itself (`<host>`), installing it from the ISO (`<host>-installer`), and upgrades and rollbacks (`<host>-upgrade`) |

### Adding a service

A service any host could run gets its own file, `modules/services/<name>.nix`
(listed in `modules/services/default.nix`), or a directory once it has a
script or a second file. It does nothing until the host switches it on with
the service's own NixOS option, such as `services.sonarr.enable = true;` in
`hosts/<host>/default.nix`; only services NixOS lacks get a
`machine.<name>.enable` of their own (`machine.gitServer`). The file then
declares, under `lib.mkIf cfg.enable`:

- its ports, in `machine.firewall.internalTCPPorts` (private networks and Tailscale only);
- its health: `machine.healthchecks.services.<unit>.url` for a long-running
  service with a health endpoint, `machine.healthchecks.checks` for anything else;
- its secrets, by name in `machine.secrets.use`, read from `machine.secrets.paths`;
- the only paths it may write, in `machine.sandbox.<unit>.writes`: the rest of
  the file system is read-only to it, and it must run as a user of its own,
  not root (`machine.sandbox.<unit>.root` for the exception, with the reason).
  Paths only one host has, such as endor's shares, are that host's to add.
- its command, `machine.serviceCommands.<name>.unit`, which gives
  `<name> logs`, `follow`, `errors`, `status`, `start`, `stop` and `restart`.
  If the service's own package puts a program of that name on PATH, set
  `passthrough` to it; any other clash fails the build.

A switched-on service is installed but not started at boot until the host's
`hosts/<host>/autostart.nix` lists its systemd unit: `machine.autostart.sonarr
= true;`. Until then it can be tried with `systemctl start sonarr` without
failing the boot healthchecks, and its healthchecks and Gatus alerts are left
out. The file sets its own unit to `machine.autostart.<unit> = lib.mkDefault
false;`, and one whose service brings companion units (an init unit, a timer,
a login) or a `command` healthcheck reads `config.machine.autostart.<unit>` to
switch those off with it; `unit` healthchecks follow it on their own. A
service with no unit of its own also adds its name to
`machine.autostartUnitless`, and decides itself what being off means: the git
server still answers over SSH, without its healthcheck.

A shell script goes beside its module as `<name>.sh`, built with
`machineLib.mkScript`, with its tests beside it as `<name>.test.sh` (listed in
`tests/scripts.nix`). Something only one host runs goes in `hosts/<host>/`
until a second host needs it. No Nix file is over 300 lines: `make fmt-check`
fails on one that is.

## Make targets

Run `make` for the list. Requires [Nix](https://determinate.systems/nix-installer/),
except `make test-local`. `make test`, `make check` and `make iso` need x86_64 Linux
(the VM tests also need KVM); CI runs them, and the ISO can be downloaded from the workflow run.

CI runs the same targets as a checkout does, and nothing else: `make release` on every
push to main, then `make isos`; `make update` every Monday. Each takes what it needs from
where it runs: origin and its credentials, the git identity (`GIT_AUTHOR_*` in CI), and
whatever `make check` can run there, so on a Mac `make update` commits the new lock and
stops at `check`, before pushing anything.

## Testing

| Check | What |
| --- | --- |
| `script-upgrade`, `script-verify`, `script-install`, `script-healthcheck`, `script-service-command` | The self-upgrade, installer, healthcheck and service command scripts against stubbed commands, one case per behaviour (seconds, no VM) |
| `<host>` | The host in a VM next to a client: healthchecks, SSH, git, the service commands |
| `<host>-installer` | The ISO refuses a used disk, installs onto a blank one, and the host boots from it |
| `<host>-upgrade` | From an image of the installed host, its ISO still attached: a good release is kept; one failing its healthchecks, and one that can't boot, are rolled back and not retried |

CI runs every check on x86_64 with KVM (`make check`), and only a passing run moves
`release`. On a Mac without Nix, `make test-local` runs the same checks for aarch64 in
Docker Desktop (give it 16 GB of memory). An M1 can't nest virtualization, so the VMs are
emulated: the host test takes about 3 minutes, the installer and upgrade tests 10 to 15
each, plus building their ISO and disk image when the system has changed. An arm64 pass
shows the logic and disk layout work, so it is worth having before pushing; it doesn't show
that the x86_64 system the machines run works. Only CI shows that.

## How a machine stays healthy

Every module declares healthchecks (`machine.healthchecks.checks`): ports that must
accept connections, units that must be active, commands that must succeed. They
run as `healthcheck.service` at every boot and in the CI VM test. They live in
`modules/healthchecks/` and always run, whatever monitoring the host has.

Long-running services also declare a health endpoint (`machine.healthchecks.services`).
systemd keeps such a unit `activating` until its endpoint answers, so the unit's
state is its health: **activating** is starting, **active** is healthy, **failed**
is unhealthy (no answer within its `startTimeout`). The healthchecks wait for a
starting unit up to its own allowance (15 minutes for Sonarr, Radarr and
NZBHydra2, 5 for the rest), fail an unhealthy one at once, and stop waiting after
the first failure. The upgrade gate only asks for an answer short of a server error,
so a login page counts; Gatus checks the answer itself.

`self-upgrade.timer` checks the `release` branch every 30 minutes. A new commit
that changes the system is built, made a **one-shot** boot entry while the
running system stays the default, and rebooted into. On that boot:

- healthchecks pass: the new system becomes the default.
- healthchecks fail: roll back to the previous system and reboot.
- the new system panics or fails in early boot: the kernel reboots
  (`panic=10`, `boot.panic_on_fail`) into the default, which is still the old system.

Failed commits are recorded in `/var/lib/self-upgrade/bad-revs` and skipped until
`release` moves. A system that has already been confirmed is never rolled back
further, so a failure unrelated to an upgrade won't cause a reboot loop.
`make status HOST=manaan` shows the state.

Data is not covered by rollback. Snapshot the zvol from TrueNAS.

## What manaan runs

| Service | Where | Port |
| --- | --- | --- |
| SSH, git server, its repos on endor at `/mnt/endor/repos` | `modules/services/ssh.nix`, `modules/services/git-server/` | 22 |
| Docker, for compose projects run by hand | `modules/services/docker.nix` | whatever they publish |
| Syncthing, with the old host's device identity | `modules/services/syncthing.nix`, `hosts/manaan/syncthing.nix` | 8384 (web UI), 22000, 21027/udp |
| NZBHydra2, Sonarr, Radarr, SABnzbd | `modules/services/{nzbhydra2,sonarr,radarr,sabnzbd}.nix` | 5076, 8989, 7878, 8080 |
| endor's NFS and SMB shares under `/mnt/endor` | `hosts/manaan/mounts.nix` | |
| Gatus, polling every health endpoint each minute | `modules/services/gatus.nix` | 8090 (status page) |
| Grafana, over Prometheus, node_exporter and cAdvisor | `modules/services/{grafana/,prometheus.nix,node-exporter.nix,cadvisor.nix}` | 3000 (web UI); the rest on localhost |

Web UIs and SSH are reachable from private networks and Tailscale only
(`machine.firewall.internalTCPPorts`). Ports Docker publishes bypass the host
firewall. Docker rotates container logs (json-file, 3 x 10M) and prunes weekly:
stopped containers, unused networks and images unused for a week; never named
volumes. The shares are mounted on first access, so the machine boots without endor.

Grafana's dashboard shows CPU, memory, disks and network, whether each healthchecked
unit is up, and CPU and memory per systemd service and per Docker container. It is
provisioned from `modules/services/grafana/dashboard/`; edits made in the web UI don't
stick. Log in as `admin` with the password generated on first start
(`sudo cat /var/lib/grafana/admin-password`). Prometheus keeps 90 days or 2GB,
whichever is less, on a volume of its own.

## Disk layout

`hosts/<host>/disko.nix`, written by the installer. Each mount is a separate LVM
volume, so a full `/var` or `/tmp` can't take `/` or `/nix` down with it:

| Mount | Size | Options |
| --- | --- | --- |
| `/boot` | 1G (GPT partition) | `umask=0077` |
| `/` | 6G | |
| `/nix` | 20G | `noatime` |
| `/var` | 10G | `nodev` |
| `/home` | 8G | `nodev,nosuid` |
| `/tmp` | 4G, cleared at boot | `nodev,nosuid` |
| `/var/lib/docker` | 100G | |
| `/var/lib/grafana` | 1G | `nodev,nosuid` |
| `/var/lib/prometheus2` | 3G: 2GB of retention, plus room to compact | `nodev,nosuid` |
| swap | 2G, `swappiness=10` | last resort against the OOM killer |

Sized for a 160G zvol, leaving ~5G of the pool unallocated. To grow a volume
on the running machine: `sudo lvextend -r -L +5G pool/var`. To grow the pool,
enlarge the zvol in TrueNAS, then `sudo growpart /dev/vda 2 && sudo pvresize /dev/vda2`.

## Setting up a new machine

Each host has an installer ISO (`make iso`, or the `installer-isos` artifact
from the latest `release` run on main). It contains the whole system, so
installing needs no network. When it boots:

- every disk in the host's `disko.nix` is blank (no partitions, no signatures):
  format, install, print the new SSH host key fingerprint, reboot into the disk.
- any disk is not blank: do nothing. The ISO never overwrites a disk.
- the install fails part way: wipe the disk back to blank so the next boot retries.

For a TrueNAS VM:

1. Create the VM with UEFI boot, a VirtIO NIC, the zvol (at least 160G) as a VirtIO disk with
   boot order 1001, and the ISO as a CD-ROM with boot order 1002. The ISO can stay
   attached: once installed, the disk boots first. If the zvol is ever wiped,
   the next boot reinstalls.
2. Start it and watch the console (Display or Serial Shell). It reboots into
   the installed system and prints a `host key:` line on the way, and a `mac:` line
   per network card. manaan uses DHCP: reserve its address on the router for that MAC.
   The MAC is also under the VM's NIC device in TrueNAS, so the reservation can be made first.
3. `make enroll HOST=manaan ADDR=<vm ip>` fetches the host key, shows its
   fingerprint to compare with the console, and re-encrypts secrets for it. Commit
   and push; the machine picks up its secrets (Tailscale, root password, the
   Syncthing keys, the SMB login) on the next upgrade. Until then it is reachable only over SSH on the LAN.

Secrets are created with `make secret NAME=tailscale-authkey` (a reusable,
pre-approved key; until it exists, Tailscale isn't logged in or healthchecked) and `make secret NAME=root-password` (output of
`mkpasswd -m yescrypt`). `secrets/syncthing-key.age` and `syncthing-https-key.age` hold
the old host's Syncthing `key.pem` and `https-key.pem`. `make secret NAME=smb-credentials`
takes the `username=`/`password=` lines for endor's SMB shares; until it exists those two
shares aren't mounted. `make secret NAME=ntfy` (`NTFY_URL=https://ntfy.sh` and
`NTFY_TOPIC=<topic>` lines) turns on notifications: a unit with a health endpoint, or
the healthchecks, failing, and Gatus alerts. A reinstall creates a new host key, so enroll again.

## One-time GitHub setup

- Protect `release` (only GitHub Actions may push). `main` must let GitHub Actions push,
  since the weekly update pushes to it.
- Settings → Actions → General → Workflow permissions: read and write.
