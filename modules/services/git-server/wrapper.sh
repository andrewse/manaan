# sshd ForceCommand for the git user: only git transport commands, only on
# repos inside $repo_dir. Prepended with `repo_dir=...` by default.nix.

# log <priority> <message>: to the journal as git-server, which is what
# `git-server logs` reads. A push or pull never fails because of it.
from=${SSH_CONNECTION:-unknown}
from=${from%% *}
log() {
  logger --tag git-server --priority "user.$1" -- "$2 (from $from)" || true
}

deny() {
  log warning "refused ${request:-a shell}: ${1:-Access denied}"
  echo "${1:-Access denied}" >&2
  exit 1
}

request=${SSH_ORIGINAL_COMMAND:-}
[[ -n $request ]] || deny "Interactive login is not allowed"

cmd=${request%% *}
path=${request#* }
[[ $path != "$request" ]] || deny

case $cmd in
  git-receive-pack | git-upload-pack | git-upload-archive) ;;
  *) deny ;;
esac

# git sends 'name.git' for scp-style URLs and '/name.git' for ssh:// URLs.
path=${path#\'}
path=${path%\'}
path=${path#/}

valid='^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*\.git$'
[[ $path =~ $valid ]] || deny
[[ $path != *..* ]] || deny

repo=$repo_dir/$path
if [[ ! -d $repo ]]; then
  [[ $cmd == git-receive-pack ]] || deny "No such repository: $path"
  mkdir -p "$(dirname "$repo")"
  git init --quiet --bare --shared=group "$repo" >&2
  log info "created $path"
fi

log info "$cmd $path"
exec "$cmd" "$repo"
