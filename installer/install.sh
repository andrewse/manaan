# Prepended with host, hostKey, efi, system, disko and disks by default.nix.

if [[ ! -d $efi ]]; then
  echo "not booted with UEFI; set the VM to UEFI boot. Not installing $host."
  exit 1
fi

udevadm settle
for disk in "${disks[@]}"; do
  if ! lsblk --nodeps "$disk" >/dev/null 2>&1; then
    echo "$disk does not exist. Not installing $host."
    exit 1
  fi
  if [[ -n $(lsblk --noheadings --output NAME "$disk" | tail -n +2) || -n $(wipefs --no-act "$disk") ]]; then
    echo "$disk is not blank. Not installing $host; this installer never overwrites a disk."
    exit 1
  fi
done

# The ISO's sshd already serves the key the host will have, so it can be checked
# against the first SSH connection now, and SSH sees no change after the
# reboot. Without it, stop before touching the disks.
if ! fingerprint=$(ssh-keygen -l -f "$hostKey.pub"); then
  echo "no SSH host key at $hostKey. Not installing $host."
  exit 1
fi

echo "installing $host onto ${disks[*]}"
echo "host key: $fingerprint"

# If anything fails from here, put the disks back to blank so the next boot retries.
wipe() {
  echo "installing $host failed; wiping ${disks[*]} so the next boot can retry"
  umount -R /mnt || true
  swapoff --all || true
  vgchange --activate n || true
  lsblk --list --noheadings --paths --output NAME "${disks[@]}" | tac | xargs wipefs --all
}
trap wipe ERR

"$disko" --yes-wipe-all-disks

install -d -m755 /mnt/etc/ssh
install -m600 "$hostKey" /mnt/etc/ssh/ssh_host_ed25519_key
install -m644 "$hostKey.pub" /mnt/etc/ssh/ssh_host_ed25519_key.pub

nixos-install --system "$system" --no-root-passwd --no-channel-copy --option substituters ""

trap - ERR
# The VM's network cards, for a DHCP reservation on the router.
for iface in /sys/class/net/*; do
  if [[ -e $iface/device ]]; then
    echo "mac: ${iface##*/} $(<"$iface/address")"
  fi
done
echo "installed $host, rebooting"
umount -R /mnt
systemctl reboot
