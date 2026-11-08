"""A host under test: a QEMU VM on the machine running the tests, seen from outside.

The tests reach it only as its users would: SSH as an admin, its ports
through QEMU's user network (the runner is on a private network to it, so its
internal-only ports answer), and the serial console, where the firmware, the
kernel and the installer write. Its release branch is a git daemon on the
runner. QEMU is the one on PATH, with the UEFI firmware it ships; the VM is
accelerated by HVF on macOS and KVM on Linux, when it is the machine's own
architecture.
"""

import fnmatch
import json
import os
import platform
import re
import shlex
import shutil
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

# Where QEMU forwards the release branch's git daemon, in tests/system/tested.nix.
GIT_ADDRESS = "10.0.2.100:9418"
# What firmware descriptors call each machine type, versioned: virt-11.1, pc-q35-11.1.
MACHINE_TYPES = {"virt": "virt", "q35": "pc-q35"}
# What the firmware writes on the console as it starts each boot, naming the device.
FIRMWARE_START = re.compile(r'BdsDxe: starting Boot[0-9A-F]{4} "([^"]*)"')


class Image:
    """What `make system-image` built for a host: tests/system/default.nix."""

    def __init__(self, path):
        self.path = Path(path).resolve()
        self.facts = json.loads((self.path / "host.json").read_text())
        self.name = self.facts["name"]
        self.arch = self.facts["arch"]

    def __getitem__(self, key):
        return self.facts[key]


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def accelerator(arch):
    """The fastest way this machine runs `arch`: (accelerator, cpu)."""
    native = {"arm64": "aarch64", "amd64": "x86_64"}.get(platform.machine(), platform.machine())
    if native == arch:
        if platform.system() == "Darwin":
            return "hvf", "host"
        if os.access("/dev/kvm", os.R_OK | os.W_OK):
            return "kvm", "host"
    # Emulated. arm64's UEFI firmware hangs after its banner on a CPU with
    # FEAT_LPA2 (52-bit physical addresses), which `max` has.
    return "tcg", "max,lpa2=off" if arch == "aarch64" else "max"


def firmware(arch, machine):
    """QEMU's UEFI firmware for `arch` and `machine`, without Secure Boot:
    (code, variables template). From the firmware descriptors QEMU's packages
    install (docs/interop/firmware.json), in their order of preference."""
    listed = subprocess.run([f"qemu-system-{arch}", "-L", "help"], capture_output=True, text=True, check=True)
    dirs = [Path(d) / "firmware" for d in listed.stdout.split()]
    dirs += [Path("/etc/qemu/firmware"), Path("/usr/share/qemu/firmware")]
    descriptors = sorted({p for d in dirs if d.is_dir() for p in d.glob("*.json")}, key=lambda p: p.name)
    for path in descriptors:
        d = json.loads(path.read_text())
        mapping = d.get("mapping", {})
        if (
            "uefi" in d.get("interface-types", [])
            and mapping.get("device") == "flash"
            and not {"secure-boot", "enrolled-keys", "requires-smm"} & set(d.get("features", []))
            and any(
                t["architecture"] == arch and any(fnmatch.fnmatch(f"{MACHINE_TYPES[machine]}-x", m) for m in t["machines"])
                for t in d.get("targets", [])
            )
            and "nvram-template" in mapping
        ):
            return Path(mapping["executable"]["filename"]), Path(mapping["nvram-template"]["filename"])
    raise FileNotFoundError(f"no UEFI firmware for {arch} {machine} in {[str(d) for d in dirs]}")


def until(condition, timeout, what, interval=2):
    """Calls `condition` until it returns something true, and returns that."""
    deadline = time.monotonic() + timeout
    while True:
        result = condition()
        if result:
            return result
        if time.monotonic() > deadline:
            raise TimeoutError(f"timed out after {timeout}s waiting for {what}")
        time.sleep(interval)


class Machine:
    """One VM: the host booted from `disk`, with its installer ISO attached after it.

    `ports` are the host's TCP ports to forward to the runner, as
    `machine.port(guest)`. `releases`, a directory, is served as the release
    branch's repository.
    """

    def __init__(self, image, workdir, disk, key, vars=None, releases=None, ports=(), cores=4, memory=4096):
        self.image = image
        self.workdir = Path(workdir)
        self.workdir.mkdir(parents=True, exist_ok=True)
        self.disk = Path(disk)
        self.key = key
        self.console_log = self.workdir / "console.log"
        self.machine = "virt" if image.arch == "aarch64" else "q35"
        self.firmware, template = firmware(image.arch, self.machine)
        self.vars = self.workdir / "firmware-vars.fd"
        shutil.copyfile(vars or template, self.vars)
        self.vars.chmod(0o644)
        self.releases = releases
        self.ports = {guest: free_port() for guest in [22, *ports]}
        self.cores = cores
        self.memory = memory
        self.process = None

    def qemu(self):
        accel, cpu = accelerator(self.image.arch)
        forwards = [f"hostfwd=tcp:127.0.0.1:{host}-:{guest}" for guest, host in self.ports.items()]
        if self.releases:
            # One git daemon per connection, so no port to allocate on the runner.
            daemon = f"git daemon --inetd --export-all --base-path={self.releases} {self.releases}"
            forwards.append(f"guestfwd=tcp:{GIT_ADDRESS}-cmd:{daemon}")
        iso = self.image.path / "installer.iso"
        return [
            f"qemu-system-{self.image.arch}",
            "-machine", f"{self.machine},accel={accel}",
            "-cpu", cpu,
            "-smp", str(self.cores),
            "-m", str(self.memory),
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={self.firmware}",
            "-drive", f"if=pflash,format=raw,unit=1,file={self.vars}",
            "-drive", f"if=none,id=disk,format=qcow2,file={self.disk}",
            "-device", "virtio-blk-pci,drive=disk,bootindex=1",
            # The ISO stays attached after the disk, as on TrueNAS. A CD-ROM on
            # SCSI rather than IDE, which arm64's machine type lacks.
            "-device", "virtio-scsi-pci,id=scsi",
            "-drive", f"if=none,id=cd,media=cdrom,readonly=on,format=raw,file={iso}",
            "-device", "scsi-cd,drive=cd,bus=scsi.0,bootindex=2",
            "-netdev", ",".join(["user,id=net", *forwards]),
            "-device", "virtio-net-pci,netdev=net",
            "-device", "virtio-rng-pci",
            # The admin's public key, which tests/system/tested.nix authorizes.
            "-smbios", f"type=11,value=io.systemd.credential:tester.ssh={self.public_key()}",
            "-chardev", f"file,id=console,path={self.console_log}",
            "-serial", "chardev:console",
            "-display", "none",
            "-monitor", "none",
        ]

    def start(self):
        self.console_log.unlink(missing_ok=True)
        self.console_log.touch()
        self.process = subprocess.Popen(
            self.qemu(), stdin=subprocess.DEVNULL, stderr=open(self.workdir / "qemu.log", "w")
        )

    def running(self):
        return self.process is not None and self.process.poll() is None

    def kill(self):
        if self.running():
            self.process.kill()
            self.process.wait()

    def poweroff(self, timeout=300):
        self.ssh("sudo -n systemctl poweroff", check=False)
        self.process.wait(timeout)

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *_):
        self.kill()

    def public_key(self):
        return Path(f"{self.key}.pub").read_text().strip()

    def port(self, guest):
        return self.ports[guest]

    # The console.

    def console(self):
        return self.console_log.read_text(errors="replace")

    def _alive(self):
        if not self.running():
            raise RuntimeError(f"QEMU exited ({self.process.returncode}); see {self.workdir / 'qemu.log'}")

    def wait_for_console(self, pattern, timeout=900):
        """Waits for `pattern`, a regex, on the console; returns the match."""

        def found():
            self._alive()
            return re.search(pattern, self.console())

        return until(found, timeout, f"{pattern!r} on the console", interval=1)

    def boots(self):
        """The device the firmware started each boot from, in order."""
        return FIRMWARE_START.findall(self.console())

    def wait_for_boots(self, count, from_iso=0, timeout=900):
        """Waits for the firmware to have started `count` boots, failing as soon as one
        after the first `from_iso` starts the ISO."""

        def started():
            self._alive()
            devices = self.boots()
            assert not any("CD-ROM" in d for d in devices[from_iso:]), f"the firmware booted the ISO: {devices}"
            return len(devices) >= count

        until(started, timeout, f"boot {count} to start from the disk", interval=1)

    # SSH, as the tests' admin.

    def ssh_command(self, user="tester"):
        return [
            "ssh", "-i", str(self.key), "-p", str(self.port(22)),
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
            f"{user}@127.0.0.1",
        ]

    def ssh(self, command, user="tester", check=True, timeout=600):
        """Runs `command` on the host over SSH; returns the CompletedProcess."""
        result = subprocess.run(
            [*self.ssh_command(user), command], capture_output=True, text=True, timeout=timeout
        )
        if check and result.returncode != 0:
            raise AssertionError(
                f"{command!r} as {user} exited {result.returncode}\n{result.stdout}{result.stderr}"
            )
        return result

    def succeed(self, command, timeout=600):
        """Runs `command` as root, through the admin's sudo; returns its output."""
        return self.ssh(f"sudo -n sh -c {shlex.quote(command)}", timeout=timeout).stdout

    def fails(self, command, timeout=600):
        """Whether `command`, as root, exits non-zero."""
        return self.ssh(f"sudo -n sh -c {shlex.quote(command)}", check=False, timeout=timeout).returncode != 0

    def boot_id(self):
        """The running boot's id, or None while SSH doesn't answer."""
        try:
            result = self.ssh("cat /proc/sys/kernel/random/boot_id", check=False, timeout=30)
        except subprocess.TimeoutExpired:
            return None
        return result.stdout.strip() if result.returncode == 0 else None

    def wait_for_ssh(self, other_than=None, timeout=900):
        """Waits for SSH to answer, from a boot other than `other_than`; returns its boot id."""

        def answered():
            self._alive()
            boot = self.boot_id()
            return boot if boot and boot != other_than else None

        return until(answered, timeout, "SSH" + (" after a reboot" if other_than else ""))

    def wait_for_unit(self, unit, timeout=900):
        """Waits for `unit` to be active, failing as soon as it has failed."""

        def active():
            state = self.ssh(f"systemctl show -P ActiveState {unit}", timeout=30).stdout.strip()
            assert state != "failed", f"{unit} failed:\n" + self.succeed(f"journalctl -b -u {unit} --no-pager | tail -n 50")
            return state == "active"

        until(active, timeout, f"{unit} to be active")

    def http(self, guest_port, path, timeout=10):
        """GETs `path` from the host's `guest_port`, from the runner; returns the body."""
        url = f"http://127.0.0.1:{self.port(guest_port)}{path}"
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.read().decode()


def keygen(path):
    """Makes the tests' admin a key at `path`, and `path`.pub; returns `path`."""
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "tester@system-tests", "-f", path], check=True
    )
    return path


def installed(image, cache, key, timeout=3600):
    """The host installed from its ISO onto a blank disk, then booted once, cached
    until the image changes: (disk, firmware variables, install console log).
    Machines start from it through a copy-on-write overlay."""
    cache = Path(cache)
    source = (image.path / "source").read_text()
    disk, vars, log = cache / "disk.qcow2", cache / "firmware-vars.fd", cache / "install.log"
    if (cache / "source").exists() and (cache / "source").read_text() == source:
        return disk, vars, log

    shutil.rmtree(cache, ignore_errors=True)
    cache.mkdir(parents=True)
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", disk, "200G"], check=True)
    with Machine(image, cache / "run", disk, key) as host:
        # Also match the failure, so a failed install fails here and not at the timeout.
        host.wait_for_console(f"installed {image.name}, rebooting|installing {image.name} failed", timeout)
        assert f"installing {image.name} failed" not in host.console(), "the installer failed"
        # It reboots itself, from the disk this time.
        host.wait_for_boots(2, from_iso=1)
        host.wait_for_ssh()
        host.wait_for_unit("multi-user.target")
        shutil.copyfile(host.console_log, log)
        host.poweroff()
        shutil.copyfile(host.vars, vars)
    shutil.rmtree(cache / "run")
    (cache / "source").write_text(source)
    return disk, vars, log


def overlay(base, path):
    """A copy-on-write disk at `path` over `base`, leaving `base` as it is."""
    subprocess.run(
        ["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", Path(base).resolve(), path],
        check=True,
    )
    return path
