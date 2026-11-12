"""Upgrading the installed host, booted under UEFI from its own disk: it must
keep a good release, and roll back a release that fails its healthchecks or
cannot boot -- what the real firmware and boot loader do with the entries
self-upgrade sets. integration-rollback tells the same story against a fake
firmware, and also that a failed release is tried again, up to three times,
before it is skipped.

The installer ISO stays attached throughout, as on TrueNAS, and it installs
the system the disk starts from, so every release moves the disk past it.
Every boot must still start from the disk.

The tests run in order, each on the host the one before left: a failure makes
those after it fail too."""

import subprocess

import pytest

from machine import until


class Upgrades:
    """Plays CI, publishing releases to the branch, and watches the host take them."""

    def __init__(self, host, releases, key):
        self.host = host
        self.repo = releases / "release.git"
        # The admin key the host trusts to sign a release (tested.nix).
        self.key = key
        self.boots = len(host.boots())
        self.boot = host.boot_id()
        # The release the host has confirmed and keeps: (commit, system).
        self.kept = None

    def publish(self, system):
        """Commits `system` to the release branch, signed; returns the commit."""
        git = ["git", "-C", self.repo, "-c", "user.name=ci", "-c", "user.email=ci@localhost"]
        sign = ["-c", "gpg.format=ssh", "-c", f"user.signingkey={self.key}"]
        (self.repo / "system").write_text(system + "\n")
        subprocess.run([*git, "add", "system"], check=True)
        subprocess.run([*git, *sign, "commit", "-S", "-q", "-m", system], check=True)
        return subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()

    def reconnect(self, boots=1):
        """Waits for the boot `boots` boots on from the last, started from the disk, and for its SSH."""
        self.boots += boots
        self.host.wait_for_boots(self.boots)
        self.boot = self.host.wait_for_ssh(other_than=self.boot)

    def reboot(self):
        self.host.ssh("sudo -n systemctl reboot", check=False)
        self.reconnect()

    def upgrade_to(self, rev, boots=1):
        """Starts self-upgrade, and waits for it to reboot into `rev` and for SSH `boots` boots on."""
        self.host.ssh("sudo -n systemctl start --no-block self-upgrade.service")

        def rebooted():
            state = self.host.ssh("systemctl show -P ActiveState self-upgrade.service", check=False, timeout=30)
            assert state.stdout.strip() != "failed", "self-upgrade failed to stage the release:\n" + self.host.succeed(
                "journalctl -b -u self-upgrade --no-pager | tail -n 50"
            )
            return len(self.host.boots()) > self.boots

        until(rebooted, 900, f"self-upgrade to reboot into {rev}")
        self.reconnect(boots)

    def booted(self, system, kept_rev=None):
        """Waits for the boot to settle, then checks it is running `system` with no upgrade on trial."""
        self.host.wait_for_unit("self-upgrade-verify.service")
        self.host.succeed(
            f"test $(readlink -f /run/booted-system) = {system}"
            f" && test $(readlink -f /nix/var/nix/profiles/system) = {system}"
            " && test ! -e /var/lib/self-upgrade/pending"
            " && systemctl is-active healthcheck.service"
        )
        if kept_rev is not None:
            self.host.succeed(f"test $(cat /var/lib/self-upgrade/rev) = {kept_rev}")

    def journal(self, unit, boot):
        """`unit`'s journal from `boot` (0 this one, -1 the one before)."""
        return self.host.succeed(f"journalctl -b {boot} -u {unit} --no-pager")


@pytest.fixture(scope="module")
def upgrades(boot, releases, image, key):
    host = boot(releases=releases)
    upgrades = Upgrades(host, releases, key)
    upgrades.booted(image["installed"])
    return upgrades


def test_a_good_release_is_booted_once_confirmed_and_kept_across_a_reboot(upgrades, image):
    good = image["releases"]["good"]
    rev = upgrades.publish(good)
    upgrades.upgrade_to(rev)
    assert f"rebooting into {rev}" in upgrades.journal("self-upgrade", -1)
    upgrades.booted(good, kept_rev=rev)
    upgrades.reboot()
    upgrades.booted(good, kept_rev=rev)
    upgrades.kept = rev, good


def test_a_release_that_fails_its_healthchecks_is_rolled_back_and_rebooted(upgrades, image):
    failing = upgrades.publish(image["releases"]["fails-healthchecks"])
    upgrades.upgrade_to(failing)
    # It boots, fails, and reboots into the kept release.
    upgrades.reconnect()
    assert f"upgrade to {failing} failed its healthchecks" in upgrades.journal("self-upgrade-verify", -1)
    rev, system = upgrades.kept
    upgrades.booted(system, kept_rev=rev)
    upgrades.host.succeed(f"grep -qxF {failing} /var/lib/self-upgrade/bad-revs")


def test_a_release_that_cannot_boot_falls_back_to_the_kept_release(upgrades, image):
    unbootable = upgrades.publish(image["releases"]["unbootable"])
    # It panics, and the firmware starts the kept release.
    upgrades.upgrade_to(unbootable, boots=2)
    assert "Kernel panic" in upgrades.host.console()
    assert f"upgrade to {unbootable} never finished booting" in upgrades.journal("self-upgrade-verify", 0)
    rev, system = upgrades.kept
    upgrades.booted(system, kept_rev=rev)
    upgrades.host.succeed(f"grep -qxF {unbootable} /var/lib/self-upgrade/bad-revs")
