# shellcheck shell=bash
# What the git user's ForceCommand lets through, and what it logs. git, its
# transport commands and logger are stubbed; tests/integration/git-server.test.sh
# pushes and clones through it with the real git.

# On PATH; see tests/unit.nix.
source script-harness.sh
# wrapper.sh, beside this file.
scripts=$(dirname "$0")

# wrapper [<command>]: runs the wrapper the way sshd does for the git user, with
# <command> as the one the client asked for, or none, as for a login.
wrapper() {
  stub "$root/bin/logger" logger "${logger_fails:+exit 1}"
  stub "$root/bin/git" git
  for transport in git-receive-pack git-upload-pack git-upload-archive; do
    stub "$root/bin/$transport" "$transport"
  done
  run "repo_dir=$(printf %q "$root/repos")
SSH_CONNECTION='10.0.0.5 50022 10.0.0.1 22'
${1+SSH_ORIGINAL_COMMAND=$(printf %q "$1")}" "$scripts/wrapper.sh"
}

# expect_logged <priority> <message>: logged as git-server, from the client.
expect_logged() {
  expect_called "logger --tag git-server --priority user.$1 -- $(printf %q "$2 (from 10.0.0.5)")"
}

# expect_refused <command>: the wrapper refuses <command> and runs nothing.
expect_refused() {
  wrapper "$1"
  [[ $status == 1 ]] || fail "$1: exit status $status, expected 1"
  ! grep -q '^git' "$root/calls" || fail "$1: ran $(grep '^git' "$root/calls" | head -n1)"
  : >"$root/calls"
}

begin "a login: refused, and logged as a refusal"
wrapper
expect_status 1
expect_output "Interactive login is not allowed"
expect_logged warning "refused a shell: Interactive login is not allowed"

begin "a command that isn't git's: refused, and logged with what was asked"
wrapper "rm -rf /"
expect_status 1
expect_output "Access denied"
expect_logged warning "refused rm -rf /: Access denied"
expect_not_called git

begin "a git command with no repository, or something else as one: refused"
expect_refused "git-upload-pack"
expect_refused "git-upload-pack 'notarepo'"
expect_refused "git-upload-pack ''"
expect_refused "git-upload-pack '.hidden.git'"
expect_refused "git-receive-pack 'a b.git'"

begin "a path outside the repo dir: refused"
expect_refused "git-receive-pack '../escape.git'"
expect_refused "git-receive-pack '/../escape.git'"
expect_refused "git-receive-pack 'team/../../escape.git'"
expect_refused "git-receive-pack '~/escape.git'"
expect_refused "git-receive-pack '//etc/escape.git'"
expect_missing escape.git
expect_missing repos

begin "a push to a repo that doesn't exist: created bare and shared with the group, then received"
wrapper "git-receive-pack 'team/new.git'"
expect_status 0
expect_called "git init --quiet --bare --shared=group $root/repos/team/new.git"
expect_called "git-receive-pack $root/repos/team/new.git"
expect_logged info "created team/new.git"
expect_logged info "git-receive-pack team/new.git"

begin "a clone of a repo that doesn't exist: refused, and nothing created"
wrapper "git-upload-pack 'missing.git'"
expect_status 1
expect_output "No such repository: missing.git"
expect_logged warning "refused git-upload-pack 'missing.git': No such repository: missing.git"
expect_not_called git
expect_missing repos/missing.git

begin "a clone of a repo that exists, by an ssh:// URL: served from the repo dir"
mkdir -p "$root/repos/project.git"
wrapper "git-upload-pack '/project.git'"
expect_status 0
expect_called "git-upload-pack $root/repos/project.git"
expect_logged info "git-upload-pack project.git"
expect_not_called git

begin "an archive of a repo that exists: served"
mkdir -p "$root/repos/project.git"
wrapper "git-upload-archive 'project.git'"
expect_status 0
expect_called "git-upload-archive $root/repos/project.git"

begin "the journal can't be written: the push still goes through"
mkdir -p "$root/repos/project.git"
logger_fails=1 wrapper "git-receive-pack 'project.git'"
expect_status 0
expect_called "git-receive-pack $root/repos/project.git"

finish
