"""`make vm`: boots the host's system test image, installed, and leaves it
running to look around in, as the tests' admin. Installs it first if the image
has changed. Usage: vm.py <image>; Ctrl-C stops it."""

import shlex
import shutil
import signal
import sys
import tempfile
from pathlib import Path

from machine import Image, Machine, installed, keygen, overlay


def main(path):
    image = Image(path)
    workdir = Path(tempfile.mkdtemp(prefix=f"{image.name}-vm-"))
    key = keygen(workdir / "tester")
    print(f"installing {image.name} if its image changed...", flush=True)
    disk, vars, _ = installed(image, image.path.parent / "installed", key)
    host = Machine(image, workdir, overlay(disk, workdir / "disk.qcow2"), key, vars=vars, ports=[3000])
    with host:
        host.wait_for_ssh()
        print(f"{image.name} is up; its console is {host.console_log}")
        print("  ssh:     " + shlex.join(host.ssh_command()))
        print(f"  grafana: http://127.0.0.1:{host.port(3000)}")
        print("Ctrl-C stops it.", flush=True)
        try:
            host.process.wait()
        except KeyboardInterrupt:
            pass
    shutil.rmtree(workdir)


if __name__ == "__main__":
    # Stopped either way, it stops the VM.
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    main(sys.argv[1])
