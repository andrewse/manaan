# machine_configs

NixOS configurations for my machines. Each machine pulls this repo and upgrades
itself; nothing is pushed to machines.

```
push to main ─► CI: format, build every host, boot every host in a VM and test it
                 │ pass
                 ▼
               CI fast-forwards `release`
                 │
machine ◄─ self-upgrade.timer: build release, boot it once, smoke test,
           keep it or roll back
```

## Layout

| Path | What |
| --- | --- |
| `flake.nix`, `flake.lock` | Inputs pinned to exact commits; same commit, same system |
| `keys.nix` | Admin users and SSH public keys (also git server access) |
| `hosts/<host>/` | Per-machine config, hardware, disk layout, `host_key.pub`, and the host's own services |
| `modules/` | Shared modules: users, ssh, firewall, tailscale, docker, git server, smoke tests, self-upgrade |
| `secrets/` | agenix-encrypted secrets and who can decrypt them |
| `installer/` | Self-installing ISO, one per host |
| `tests/` | Tests run in CI: the self-upgrade and installer scripts against stubs, and VM tests for every host: the host itself (`<host>`), installing it from the ISO (`<host>-installer`), and upgrades and rollbacks (`<host>-upgrade`) |

## Make targets

Run `make` for the list. Requires [Nix](https://determinate.systems/nix-installer/),
except `make test-local`. `make test`, `make check` and `make iso` need x86_64 Linux
(the VM tests also need KVM); CI runs them, and the ISO can be downloaded from the workflow run.

## Testing

| Check | What |
| --- | --- |
| `script-upgrade`, `script-verify`, `script-install` | The self-upgrade and installer scripts against stubbed commands, one case per behaviour (seconds, no VM) |
| `<host>` | The host in a VM next to a client: smoke tests, SSH, git |
| `<host>-installer` | The ISO refuses a used disk, installs onto a blank one, and the host boots from it |
| `<host>-upgrade` | From an image of the installed host: a good release is kept; one failing its smoke tests, and one that can't boot, are rolled back and not retried |

CI runs every check on x86_64 with KVM (`make check`), and only a passing run moves
`release`. On a Mac without Nix, `make test-local` runs the same checks for aarch64 in
Docker Desktop (give it 16 GB of memory). An M1 can't nest virtualization, so the VMs are
emulated: the host test takes about 3 minutes, the installer and upgrade tests 10 to 15
each, plus building their ISO and disk image when the system has changed. An arm64 pass
shows the logic and disk layout work, so it is worth having before pushing; it doesn't show
that the x86_64 system the machines run works. Only CI shows that.

## How a machine stays healthy

Every module declares smoke tests (`machine.smokeTests.checks`): ports that must
accept connections, units that must be active, commands that must succeed. They
run as `smoke-test.service` at every boot and in the CI VM test.

`self-upgrade.timer` checks the `release` branch every 30 minutes. A new commit
that changes the system is built, made a **one-shot** boot entry while the
running system stays the default, and rebooted into. On that boot:

- smoke tests pass: the new system becomes the default.
- smoke tests fail: roll back to the previous system and reboot.
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
| SSH, git server | `modules/ssh.nix`, `modules/git-server/` | 22 |
| Docker, for compose projects run by hand | `modules/docker.nix` | whatever they publish |
| Syncthing, with the old host's device identity | `hosts/manaan/syncthing.nix` | 8384 (web UI), 22000, 21027/udp |
| NZBHydra2, Sonarr, Radarr, SABnzbd | `hosts/manaan/media.nix` | 5076, 8989, 7878, 8080 |
| endor's NFS and SMB shares under `/mnt/endor` | `hosts/manaan/mounts.nix` | |

Web UIs and SSH are reachable from private networks and Tailscale only
(`machine.firewall.internalTCPPorts`). Ports Docker publishes bypass the host
firewall. Docker rotates container logs (json-file, 3 x 10M) and prunes weekly:
stopped containers, unused networks and images unused for a week; never named
volumes. The shares are mounted on first access, so the machine boots without endor.

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
| swap | 2G, `swappiness=10` | last resort against the OOM killer |

Sized for a 160G zvol, leaving ~9G of the pool unallocated. To grow a volume
on the running machine: `sudo lvextend -r -L +5G pool/var`. To grow the pool,
enlarge the zvol in TrueNAS, then `sudo growpart /dev/vda 2 && sudo pvresize /dev/vda2`.

## Setting up a new machine

Each host has an installer ISO (`make iso`, or the `installer-isos` artifact
from the latest `check` run on main). It contains the whole system, so
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
pre-approved key) and `make secret NAME=root-password` (output of
`mkpasswd -m yescrypt`). `secrets/syncthing-key.age` and `syncthing-https-key.age` hold
the old host's Syncthing `key.pem` and `https-key.pem`. `make secret NAME=smb-credentials`
takes the `username=`/`password=` lines for endor's SMB shares; until it exists those two
shares aren't mounted. A reinstall creates a new host key, so enroll again.

## One-time GitHub setup

- Protect `main` (require the `check` job) and `release` (only GitHub Actions may push).
- Settings → Actions → General → Workflow permissions: read and write.
- Optional: a `FLAKE_LOCK_TOKEN` secret (fine-grained PAT: contents + pull requests)
  so the weekly flake.lock PR triggers CI.
