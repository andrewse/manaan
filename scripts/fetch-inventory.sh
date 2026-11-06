#!/usr/bin/env bash
# Run scripts/inventory.sh on a machine and unpack its dump into inventory/.
#
#   scripts/fetch-inventory.sh [ssh-host]    (default: manaan)
#
# Asks for your sudo password on the machine.
set -euo pipefail

host=${1:-manaan}
repo=$(cd "$(dirname "$0")/.." && pwd)

scp -q "$repo/scripts/inventory.sh" "$host:inventory.sh"
# The dump is root-only; hand the tarball to the ssh user so scp can read it.
ssh -t "$host" 'sudo bash inventory.sh && sudo chown "$USER" "$(ls -t /tmp/inventory-*.tar.gz | head -1)"'
tarball=$(ssh "$host" 'ls -t /tmp/inventory-*.tar.gz | head -1')

mkdir -p "$repo/inventory"
scp -q "$host:$tarball" "$repo/inventory/"
tar -xzf "$repo/inventory/$(basename "$tarball")" -C "$repo/inventory"
echo "unpacked into inventory/$(basename "$tarball" .tar.gz)"
