"""Installing the host from its ISO, booted under UEFI the way TrueNAS does it:
disk first, installer ISO second, the ISO attached throughout. The ISO must
refuse a disk that is already in use and install onto a blank one; the host
must then boot from disk with its own layout, and not reinstall.

The install itself is the `install` fixture's, shared with the other tests,
which start from the disk it leaves."""

import re
import subprocess

import pytest

from machine import Machine


def test_a_disk_that_is_already_in_use_is_left_alone(image, key, tmp_path):
    used = image.path / "used.raw"
    disk = tmp_path / "disk.qcow2"
    subprocess.run(["qemu-img", "convert", "-O", "qcow2", used, disk], check=True)
    with Machine(image, tmp_path, disk, key) as host:
        host.wait_for_console("is not blank")
    subprocess.run(["qemu-img", "compare", "-q", used, disk], check=True)


@pytest.fixture(scope="module")
def host(boot):
    host = boot()
    host.wait_for_unit("healthcheck.service")
    return host


@pytest.fixture(scope="module")
def install_log(install):
    return install[2].read_text(errors="replace")


def host_key(host):
    return host.succeed("ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub").strip()


def test_a_blank_disk_gets_formatted_and_installed_then_boots(host, image, install_log):
    assert f"installed {image.name}, rebooting" in install_log
    assert re.search(r"mac: \S+ ([0-9a-f]{2}:){5}[0-9a-f]{2}", install_log), "no MAC address printed"
    host.succeed(
        f"test $(hostname) = {image.name} && bootctl is-installed"
        # swapon names the volume by its kernel name, /dev/dm-N.
        " && swapon --show=NAME --noheadings | grep -qxF $(readlink -f /dev/pool/swap)"
    )
    # The ISO's sshd served this key during the install, so SSH sees no change.
    assert f"host key: {host_key(host)}" in install_log, "the host's key is not the one the ISO showed"


@pytest.mark.parametrize(
    "mount, volume, options",
    [
        ("/", "pool-root", []),
        ("/nix", "pool-nix", []),
        ("/var", "pool-var", ["nodev"]),
        ("/home", "pool-home", ["nodev", "nosuid"]),
        ("/tmp", "pool-tmp", ["nodev", "nosuid"]),
        ("/var/lib/docker", "pool-docker", []),
        ("/var/lib/grafana", "pool-grafana", ["nodev", "nosuid"]),
        ("/var/lib/prometheus2", "pool-prometheus", ["nodev", "nosuid"]),
    ],
)
def test_each_mount_is_its_own_volume_with_its_mount_options(host, mount, volume, options):
    source, opts = host.succeed(f"findmnt --noheadings --output SOURCE,OPTIONS {mount}").split()
    assert source == f"/dev/mapper/{volume}", f"{mount} is on {source}"
    for option in options:
        assert option in opts.split(","), f"{mount} is missing {option}: {opts}"


def test_boot_is_the_disk_s_first_partition_and_volumes_fill_alone(host):
    host.succeed("findmnt --noheadings --output SOURCE /boot | grep -q '^/dev/vda1$'")
    # Filling one volume must not affect the others.
    assert host.fails("fallocate -l 5G /tmp/fill")
    host.succeed("rm -f /tmp/fill && touch /var/still-writable")


def test_with_the_iso_still_attached_rebooting_boots_the_disk_and_does_not_reinstall(host):
    installed = host.succeed("readlink -f /run/current-system").strip()
    key = host_key(host)
    boots = len(host.boots())
    boot = host.boot_id()
    host.ssh("sudo -n systemctl reboot", check=False)
    host.wait_for_boots(boots + 1)
    host.wait_for_ssh(other_than=boot)
    host.wait_for_unit("multi-user.target")
    host.succeed(f"test $(readlink -f /run/booted-system) = {installed}")
    assert host_key(host) == key, "host was reinstalled"
