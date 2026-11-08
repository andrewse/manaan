"""Fixtures for the system tests: the image under test, the host installed from
it, and a fresh VM of that host per test module."""

import signal
import subprocess

import pytest

from machine import Image, Machine, installed, keygen, overlay


def pytest_addoption(parser):
    parser.addoption("--image", required=True, help="what `make system-image` built: out/system/<host>/image")


def pytest_configure(config):
    # Stopped either way, the run stops its VMs.
    signal.signal(signal.SIGTERM, signal.default_int_handler)


@pytest.fixture(scope="session")
def image(request):
    return Image(request.config.getoption("--image"))


@pytest.fixture(scope="session")
def key(tmp_path_factory):
    """The test admin's private key, made for this run."""
    return keygen(tmp_path_factory.mktemp("ssh") / "tester")


@pytest.fixture(scope="session")
def install(image, key):
    """The host as its ISO installed it: (disk, firmware variables, console log).
    Cached beside the image until the image changes."""
    return installed(image, image.path.parent / "installed", key)


@pytest.fixture(scope="module")
def boot(image, key, install, tmp_path_factory):
    """Boots a VM of the installed host, on a disk of its own; stopped with the module."""
    machines = []

    def start(**options):
        disk, vars, _ = install
        workdir = tmp_path_factory.mktemp(image.name)
        host = Machine(image, workdir, overlay(disk, workdir / "disk.qcow2"), key, vars=vars, **options)
        machines.append(host)
        host.start()
        host.wait_for_ssh()
        return host

    yield start
    for host in machines:
        host.kill()


@pytest.fixture(scope="module")
def releases(tmp_path_factory):
    """The release branch's repository, which a VM started with it pulls from."""
    root = tmp_path_factory.mktemp("releases")
    subprocess.run(["git", "init", "-q", "-b", "release", root / "release.git"], check=True)
    return root
