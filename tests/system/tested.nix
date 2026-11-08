# What a host config can't do in the system tests' VM. Everything switched off
# here is untested, so keep this list short.
{ config, lib, ... }:

let
  upgrade = config.machine.selfUpgrade;
in
{
  # Needs a real auth key and the internet.
  services.tailscale.enable = lib.mkForce false;
  # The VM has no host key to decrypt with.
  machine.secrets.enable = false;
  # No file server: each share is a local directory.
  machine.localShares = true;

  # The tests' way in, as an admin. Only the test image has this key.
  machine.users.tester = [ (builtins.readFile ./ssh/tester.pub) ];

  # The release branch is the runner's git daemon, standing in for GitHub,
  # which QEMU forwards to this address. Each commit names a system already in
  # the store rather than building one, as the VM can't build the host.
  machine.selfUpgrade.url = "git://10.0.2.100/release.git";
  machine.selfUpgrade.build = ''
    repo=$(mktemp -d)
    git -C "$repo" init -q
    git -C "$repo" fetch -q "${upgrade.url}" "${upgrade.branch}"
    git -C "$repo" show "$1:system"
    rm -rf "$repo"
  '';
  # The tests decide when to upgrade.
  systemd.timers.self-upgrade.enable = false;
}
