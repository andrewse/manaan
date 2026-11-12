mkdir -p "$state"
touch "$state/bad-revs"

# The branch is fetched into a clone of our own, and the commit verified there
# is the one built from there: nothing is fetched again between the two.
clone=$state/repo
[[ -d $clone ]] || git init -q --bare -b "$branch" "$clone"
# Forced, so a rewritten branch is fetched and then refused below as a
# downgrade, rather than failing the fetch.
git -C "$clone" fetch -q --no-tags "$url" "+refs/heads/$branch:refs/heads/$branch" || {
  echo "could not fetch branch $branch from $url" >&2
  exit 1
}
rev=$(git -C "$clone" rev-parse --verify -q "refs/heads/$branch^{commit}")

deployed=$(cat "$state/rev" 2>/dev/null || true)
if [[ $rev == "$deployed" ]]; then
  echo "already at $rev"
  exit 0
fi
if grep -qxF "$rev" "$state/bad-revs"; then
  echo "$rev failed before; waiting for a newer release"
  exit 0
fi

# A refused commit is not a failed trial: it is never built, nor marked bad,
# and is refused again on every run until the branch moves past it. The unit
# fails meanwhile, so `systemctl status` and the journal say why.
refuse() {
  echo "refusing $rev from $branch: $1" >&2
  exit 1
}
git -C "$clone" -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$signers" verify-commit "$rev" ||
  refuse "it is not signed by a key in $signers"
# A fresh install has deployed nothing yet, so has nothing to descend from.
if [[ -n $deployed ]] && ! git -C "$clone" merge-base --is-ancestor "$deployed" "$rev"; then
  refuse "it does not descend from the deployed $deployed, so it would be a downgrade"
fi

echo "building $rev"
new=$(build_system "$rev")
prev=$(readlink -f "$current_system")

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
