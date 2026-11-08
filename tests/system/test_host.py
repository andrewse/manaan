"""The host as installed, checked the way it is used: its own healthchecks, and
SSH, git and its web services from another machine on the internal network,
which the runner is. Only what needs the running machine: what the git server
lets through is integration-git-server's, and what the config promises is
integration-<host>'s."""

import os
import subprocess
import urllib.error

import pytest


@pytest.fixture(scope="module")
def host(boot):
    host = boot(ports=[3000, 9090])
    host.wait_for_unit("healthcheck.service")
    return host


def test_healthchecks_pass_at_boot(host):
    host.succeed("healthcheck")


def test_services_switched_off_in_autostart_are_not_started(host, image):
    for unit in image["stopped"]:
        assert host.fails(f"systemctl is-active {unit}.service"), f"{unit} started at boot"


def test_each_service_runs_as_its_own_user_and_writes_only_where_it_is_let(host, image):
    sandbox = image["sandbox"]
    # Together, so those machine.autostart leaves off come up in parallel.
    host.succeed("systemctl start " + " ".join(f"{s['unit']}.service" for s in sandbox), timeout=1800)
    uids = {}
    for s in sandbox:
        unit = s["unit"]
        cgroup = host.succeed(f"systemctl show -P ControlGroup {unit}.service").strip()
        pid = host.succeed(f"head -n1 /sys/fs/cgroup{cgroup}/cgroup.procs").strip()
        uid = host.succeed(f"stat -c %u /proc/{pid}").strip()
        if not s["root"]:
            assert uid != "0", f"{unit} runs as root"
            assert uid not in uids, f"{unit} runs as {uids.get(uid)}'s user"
            uids[uid] = unit
        inside = f"nsenter -t {pid} -m"
        assert host.fails(f"{inside} touch /var/lib/.sandbox-probe"), f"{unit} can write /var/lib"
        for path in s["writes"]:
            # `-` marks a path that may not be there, like a share whose secret isn't.
            if path.startswith("-"):
                path = path[1:]
                if host.fails(f"{inside} test -d {path}"):
                    continue
            host.succeed(f"{inside} sh -c 'touch {path}/.sandbox-probe && rm {path}/.sandbox-probe'")


def test_each_service_command_is_the_one_on_path(host, image):
    for command in image["serviceCommands"]:
        host.ssh(f"{command} help | grep -q '^usage: {command} '")


def test_an_admin_restarts_a_service_through_its_command(host):
    host.ssh("node-exporter restart")
    host.wait_for_unit("prometheus-node-exporter.service")


def test_admins_can_ssh_in_and_sudo(host):
    host.ssh("sudo -n true")


def test_root_cannot_ssh_in(host):
    assert host.ssh("true", user="root", check=False).returncode != 0


def test_git_user_gets_no_shell(host):
    assert host.ssh("id", user="git", check=False).returncode != 0


def test_push_creates_a_repo_and_it_can_be_cloned_back(host, tmp_path):
    env = {**os.environ, "GIT_SSH_COMMAND": " ".join(host.ssh_command()[:-1])}
    url = f"ssh://git@127.0.0.1:{host.port(22)}/test.git"

    def git(*args):
        subprocess.run(["git", *args], check=True, env=env, capture_output=True)

    work, clone = tmp_path / "work", tmp_path / "clone"
    git("init", "-q", "-b", "main", work)
    git("-C", work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
    git("-C", work, "push", "-q", url, "main")
    git("clone", "-q", url, clone)
    log = subprocess.run(["git", "-C", clone, "log", "--oneline"], check=True, capture_output=True, text=True)
    assert "init" in log.stdout
    # The wrapper logs through the journal, which git-server reads.
    host.ssh("git-server logs --no-pager | grep -q 'git-receive-pack test.git'")


def test_grafana_is_reachable_from_the_internal_network_prometheus_only_locally(host):
    host.http(3000, "/api/health")
    with pytest.raises((urllib.error.URLError, ConnectionError, TimeoutError)):
        host.http(9090, "/-/ready", timeout=5)
    host.succeed(
        "curl -sf -u admin:$(cat /var/lib/grafana/admin-password)"
        " http://127.0.0.1:3000/api/dashboards/uid/machine"
    )
