mkdir -p "$state"
touch "$state/bad-revs"

rev=$(git ls-remote "https://github.com/$repo" "refs/heads/$branch" | cut -f1)
[[ -n $rev ]] || {
  echo "branch $branch not found in $repo" >&2
  exit 1
}

deployed=$(cat "$state/rev" 2>/dev/null || true)
if [[ $rev == "$deployed" ]]; then
  echo "already at $rev"
  exit 0
fi
if grep -qxF "$rev" "$state/bad-revs"; then
  echo "$rev failed before; waiting for a newer release"
  exit 0
fi

echo "building $rev"
new=$(nix build --no-link --print-out-paths \
  "github:$repo/$rev#nixosConfigurations.$host.config.system.build.toplevel")
prev=$(readlink -f /run/current-system)

if [[ $new == "$prev" ]]; then
  echo "$rev" >"$state/rev"
  echo "$rev does not change this system"
  exit 0
fi

# From here on a failure must leave the running system as the boot default.
echo "$rev $new $prev" >"$state/pending"
trap 'echo "staging $rev failed, restoring the running system" >&2; roll_back "$rev" "$prev"' ERR

# Make sure the running system has a boot entry to fall back to.
if [[ $(readlink -f "$profile") != "$prev" ]]; then
  nix-env --profile "$profile" --set "$prev"
fi
prev_gen=$(generation)
nix-env --profile "$profile" --set "$new"
new_gen=$(generation)
"$new/bin/switch-to-configuration" boot

# Keep the running system as the default and boot the new one exactly once:
# if it hangs or panics, the next boot is back on the running system.
bootctl set-default "nixos-generation-$prev_gen.conf"
bootctl set-oneshot "nixos-generation-$new_gen.conf"

trap - ERR
echo "rebooting into $rev (generation $new_gen)"
systemctl reboot
