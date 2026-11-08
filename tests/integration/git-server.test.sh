# shellcheck shell=bash
# The git server end to end, without sshd: git pushes and clones over an ssh
# that runs the git user's ForceCommand, the wrapper, as sshd does. git is the
# real one on both ends; only logger is stubbed. tests/system/host.nix pushes
# and clones through the real sshd.
#
#   git-server.test.sh <dir with wrapper.sh>

# On PATH; see tests/script-test.nix.
source script-harness.sh
wrapper=$1

# server: the git server in a fresh root, its repos in $root/repos, and
# $root/work a repo with one commit to push.
server() {
  mkdir -p "$root/repos"
  stub "$root/bin/logger" logger
  # As default.nix assembles it.
  {
    echo 'set -o errexit -o nounset -o pipefail'
    printf 'repo_dir=%q\n' "$root/repos"
    cat "$wrapper/wrapper.sh"
  } >"$root/git-ssh-wrapper"
  # The system git config programs.git gives the host, so a repo the wrapper
  # creates has main as its HEAD, as pushed.
  git config -f "$root/gitconfig" init.defaultBranch main
  # ssh <host> [<command>]: runs the wrapper with <command> as the one asked for.
  cat >"$root/bin/ssh" <<EOF
#!$BASH
shift
if ((\$#)); then export SSH_ORIGINAL_COMMAND="\$*"; fi
GIT_CONFIG_SYSTEM='$root/gitconfig' SSH_CONNECTION='10.0.0.5 50022 10.0.0.1 22' exec bash "$root/git-ssh-wrapper"
EOF
  chmod +x "$root/bin/ssh"
  git init -q -b main "$root/work"
  git -C "$root/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}

# client <git args>...: runs git as a client of the server. Sets $status and $output.
client() {
  status=0
  output=$(PATH="$root/bin:$PATH" GIT_SSH_COMMAND="$root/bin/ssh" GIT_SSH_VARIANT=simple git "$@" 2>&1) || status=$?
}

expect_logged() {
  grep -qF -- "logger --tag git-server --priority user.$1 -- $(printf %q "$2 (from 10.0.0.5)")" "$root/calls" ||
    fail "not logged as $1: $2"
}

begin "a push creates a shared bare repo, and it can be cloned back"
server
client -C "$root/work" push -q ssh://git@server/test.git main
expect_status 0
client clone -q ssh://git@server/test.git "$root/clone"
expect_status 0
[[ $(git -C "$root/clone" log --format=%s) == init ]] || fail "the clone lacks the pushed commit"
[[ $(git -C "$root/repos/test.git" rev-parse --is-bare-repository) == true ]] || fail "test.git isn't bare"
[[ $(git -C "$root/repos/test.git" config core.sharedRepository) == 1 ]] || fail "test.git isn't shared with the group"
expect_logged info "created test.git"
expect_logged info "git-receive-pack test.git"
expect_logged info "git-upload-pack test.git"

begin "a push by an scp-style URL: the same repo as by an ssh:// URL"
server
client -C "$root/work" push -q git@server:test.git main
expect_status 0
git -C "$root/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m second
client -C "$root/work" push -q ssh://git@server/test.git main
expect_status 0
[[ $(git -C "$root/repos/test.git" log --format=%s main) == $'second\ninit' ]] || fail "the pushes went to different repos"

begin "a clone of a repo that doesn't exist: refused, and nothing created"
server
client clone -q ssh://git@server/missing.git "$root/missing"
expect_failure
expect_output "No such repository: missing.git"
expect_missing repos/missing.git
expect_logged warning "refused git-upload-pack '/missing.git': No such repository: missing.git"

begin "a push to a path outside the repo dir: refused, and nothing created"
server
for url in ssh://git@server/../escape.git "ssh://git@server/~/escape.git" git@server:../escape.git; do
  client -C "$root/work" push -q "$url" main
  [[ $status != 0 ]] || fail "pushed to $url"
done
[[ -z $(find "$root" -name escape.git) ]] || fail "created $(find "$root" -name escape.git)"

begin "a login: refused"
server
client_login() {
  status=0
  output=$("$root/bin/ssh" git@server 2>&1) || status=$?
}
client_login
expect_status 1
expect_output "Interactive login is not allowed"

finish
