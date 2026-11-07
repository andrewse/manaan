let
  port = 22;
in
{
  services.openssh = {
    enable = true;
    ports = [ port ];
    openFirewall = false;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitEmptyPasswords = false;
      MaxAuthTries = 5;
      LoginGraceTime = 30;
      MaxStartups = "10:30:100";
      MaxSessions = 10;
      X11Forwarding = false;
      PermitUserEnvironment = false;
      AllowAgentForwarding = false;
      AllowTcpForwarding = false;
      PermitTunnel = false;
    };
  };
  # No sshguard: SSH is only reachable from internal networks, and sshguard's
  # block also drops established connections, cutting off admins after a few
  # failed logins.

  # SSH is only reachable from private networks and Tailscale.
  machine.firewall.internalTCPPorts = [ port ];

  machine.healthchecks.checks = {
    sshd = {
      type = "unit";
      target = "sshd.service";
    };
    ssh-port = {
      type = "tcp";
      target = "127.0.0.1:${toString port}";
    };
  };
}
