# shellcheck shell=bash disable=SC2016 # stub bodies expand in the stub
# What the installer ISO does with a disk that is already in use, and with a
# blank one when the install fails.

# On PATH; see tests/unit.nix.
source script-harness.sh
# install.sh, beside this file.
scripts=$(dirname "$0")

# install_on [disko's shell commands]: runs the installer. The disk's
# partitions come from $root/lsblk, its signatures from $root/wipefs; the
# ISO's host key is $root/key, there unless the case removes it.
install_on() {
  stub "$root/bin/ssh-keygen" ssh-keygen '[[ -e $3 ]] && echo "256 SHA256:test root@manaan (ED25519)"'
  stub "$root/bin/lsblk" lsblk '[[ $1 == --nodeps ]] || cat "$root/lsblk"'
  stub "$root/bin/wipefs" wipefs 'cat "$root/wipefs"'
  stub "$root/bin/disko" disko "${1:-}"
  stub "$root/bin/umount" umount
  stub "$root/bin/swapoff" swapoff
  stub "$root/bin/vgchange" vgchange
  mkdir -p "$root/efi"
  run "host=manaan hostKey=$(printf %q "$root/key") efi=$(printf %q "$root/efi") system=/nix/store/system disko=$(printf %q "$root/bin/disko") disks=(/dev/vda)" \
    "$scripts/install.sh"
}

begin "no SSH host key: refused, never formatted"
echo /dev/vda >"$root/lsblk"
: >"$root/wipefs"
install_on
expect_failure
expect_output "no SSH host key at $root/key"
expect_not_called disko

begin "a partitioned disk: refused, never formatted"
printf '%s\n' vda vda1 vda2 >"$root/lsblk"
: >"$root/wipefs"
install_on
expect_failure
expect_output "/dev/vda is not blank"
expect_not_called disko

begin "a disk with a filesystem on it: refused, never formatted"
echo vda >"$root/lsblk"
echo "vda 0x438 ext4 1234-abcd" >"$root/wipefs"
install_on
expect_failure
expect_output "/dev/vda is not blank"
expect_not_called disko

begin "a blank disk whose install fails: wiped back to blank"
echo /dev/vda >"$root/lsblk"
: >"$root/wipefs"
touch "$root/key.pub"
install_on "exit 1"
expect_failure
expect_output "host key: 256 SHA256:test root@manaan (ED25519)"
expect_called "disko --yes-wipe-all-disks"
expect_output "installing manaan failed; wiping /dev/vda"
expect_called "wipefs --all /dev/vda"
expect_not_called "systemctl reboot"

finish
