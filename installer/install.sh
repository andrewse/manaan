# Prepended with host, system, disko and disks by default.nix.

if [[ ! -d /sys/firmware/efi ]]; then
  echo "not booted with UEFI; set the VM to UEFI boot. Not installing $host."
  exit 1
fi

udevadm settle
for disk in "${disks[@]}"; do
  if [[ ! -b $disk ]]; then
    echo "$disk does not exist. Not installing $host."
    exit 1
  fi
  if [[ -n $(lsblk --noheadings --output NAME "$disk" | tail -n +2) || -n $(wipefs --no-act "$disk") ]]; then
    echo "$disk is not blank. Not installing $host; this installer never overwrites a disk."
    exit 1
  fi
done

echo "installing $host onto ${disks[*]}"

# If anything fails from here, put the disks back to blank so the next boot retries.
trap 'echo "installing $host failed; wiping ${disks[*]} so the next boot can retry"; umount -R /mnt || true; lsblk --list --noheadings --paths --output NAME "${disks[@]}" | tac | xargs wipefs --all' ERR

"$disko" --yes-wipe-all-disks

# Generated here rather than on first boot so the fingerprint can be shown now
# and checked against `make enroll`.
install -d -m755 /mnt/etc/ssh
ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f /mnt/etc/ssh/ssh_host_ed25519_key

nixos-install --system "$system" --no-root-passwd --no-channel-copy --option substituters ""

trap - ERR
echo "host key: $(ssh-keygen -l -f /mnt/etc/ssh/ssh_host_ed25519_key.pub)"
echo "installed $host, rebooting"
umount -R /mnt
systemctl reboot
