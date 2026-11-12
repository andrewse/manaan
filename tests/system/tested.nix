# What a host config can't do in the system tests' VM. Everything switched off
# here is untested, so keep this list short.
{ lib, ... }:

{
  # Needs a real auth key and the internet.
  services.tailscale.enable = lib.mkForce false;
  # The VM has no host key to decrypt with.
  machine.secrets.enable = false;
  # No file server: each share is a local directory.
  machine.localShares = true;

  # The tests' way in, as an admin, and as git, and the one key a release may
  # be signed with. Each run makes its own key and QEMU passes it in as a
  # credential every boot, so no key is in the image.
  machine.users.tester = [ ];
  systemd.services.tester-ssh-key = {
    description = "Authorize the system tests' SSH key";
    wantedBy = [ "sshd.service" ];
    before = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ImportCredential = "tester.ssh";
    };
    script = ''
      key=$(cat "$CREDENTIALS_DIRECTORY/tester.ssh")
      mkdir -p /run/tester-ssh
      echo "$key" > /run/tester-ssh/tester
      echo "restrict $key" > /run/tester-ssh/git
      echo "tester namespaces=\"git\" $key" > /run/tester-ssh/allowed_signers
    '';
  };
  services.openssh.authorizedKeysFiles = [ "/run/tester-ssh/%u" ];

  # The release branch is the runner's git daemon, standing in for GitHub,
  # which QEMU forwards to this address. Each commit names a system already in
  # the store rather than building one, as the VM can't build the host.
  machine.selfUpgrade.url = "git://10.0.2.100/release.git";
  machine.selfUpgrade.allowedSignersFile = "/run/tester-ssh/allowed_signers";
  machine.selfUpgrade.build = ''
    git -C "$clone" show "$1:system"
  '';
  # The tests decide when to upgrade.
  systemd.timers.self-upgrade.enable = false;
}
