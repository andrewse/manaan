#!/usr/bin/env bash
#
# The queue, exercised against a throwaway repository.
#
# A real one, not a mock: `queue.sh` is almost entirely git, and the questions
# worth asking of it -- what a stacked entry's base is, what the drain replays,
# what survives a squash -- are questions about git's answers rather than about
# this script's control flow. So the test builds a repository in a temporary
# directory, runs the real script in it, and reads what git says afterwards.
#
# It covers the HANDOVER flow in particular, because that is the part whose
# whole purpose is to still be true after the branch it refers to has been
# squashed onto main and deleted -- which cannot be checked by looking at it.
#
#   ./test.sh                run it, in the merge-queue repository
#   make queue-selftest      ...or through the make interface, once installed
#   KEEP=1 ./test.sh         keep the sandboxes and print their paths
set -euo pipefail

QUEUE=$(cd "$(dirname "$0")" && pwd)/queue.sh
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/queue-test.XXXXXX")
# Resolved, because git prints the real path and the comparisons below are
# string comparisons: on macOS $TMPDIR is a symlink into /private.
SANDBOX=$(cd "$SANDBOX" && pwd -P)
# MSANDBOX is the second repository, on `master`, and ISANDBOX the third, with
# the tooling installed inside it. Both are empty until the case that builds
# them, and `rm -rf ""` is harmless.
MSANDBOX=''
ISANDBOX=''
[ -n "${KEEP:-}" ] ||
    trap 'rm -rf "$SANDBOX" ${MSANDBOX:+"$MSANDBOX"} ${ISANDBOX:+"$ISANDBOX"}' EXIT

# `make queue-selftest` exports the repository's own QUEUE_TEST, which would
# run that repository's tests in these sandboxes. The case that wants one sets
# its own.
unset QUEUE_TEST

failures=0
checks=0

ok()   { checks=$(( checks + 1 )); printf '  ok    %s\n' "$1"; }
bad()  { checks=$(( checks + 1 )); failures=$(( failures + 1 ))
         printf '  FAIL  %s\n' "$1"
         [ $# -lt 2 ] || printf '%s\n' "$2" | sed 's/^/          /'; }
case_() { printf '\n%s\n' "$1"; }

# Run the queue in a directory under the sandbox.
q() { local dir=$1; shift; ( cd "$SANDBOX/$dir" && "$QUEUE" "$@" ); }

# Run it expecting failure, and hand back what it said.
q_fail() {
    local dir=$1 out rc=0; shift
    out=$( cd "$SANDBOX/$dir" && "$QUEUE" "$@" 2>&1 ) || rc=$?
    printf '%s\n' "$out"
    [ "$rc" != 0 ]
}

contains() {
    local what=$1 text=$2 label=$3
    case "$text" in
        *"$what"*) ok "$label" ;;
        *) bad "$label" "wanted: $what
got:
$text" ;;
    esac
}

equal() {
    local got=$1 want=$2 label=$3
    if [ "$got" = "$want" ]; then ok "$label"
    else bad "$label" "wanted: $want
got:    $got"; fi
}

commit() {
    local dir=$1 file=$2 text=$3 subject=$4
    printf '%s\n' "$text" > "$SANDBOX/$dir/$file"
    git -C "$SANDBOX/$dir" add "$file"
    git -C "$SANDBOX/$dir" commit -q -m "$subject"
}

# ---------------------------------------------------------------------------

git init -q -b main "$SANDBOX"
git -C "$SANDBOX" config user.email queue-test@example.com
git -C "$SANDBOX" config user.name 'Queue Test'
git -C "$SANDBOX" config commit.gpgsign false
printf 'start\n' > "$SANDBOX/README"
git -C "$SANDBOX" add README
git -C "$SANDBOX" commit -q -m 'start'
printf 'sandbox %s\n' "$SANDBOX"

# --- a branch, with a handover point half way along it -------------------

case_ 'a handover point on work in progress'

out=$(q . worktree sep-identity)
pwt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
pdir=${pwt#"$SANDBOX"/}
commit "$pdir" identity.go 'minted' 'sep: mint the identity on the client'
commit "$pdir" identity_test.go 'tested' 'sep: test the minted identity'

out=$(q "$pdir" handover -m 'the client-minted identity is done and tested.
The per-session directories are NOT -- edit.go is still a stub.')
contains 'handover/sep-identity/1' "$out" 'the point is named after its branch'
contains 'in progress, not submitted yet' "$out" 'it says where the work below it stands'
handover_commit=$(git -C "$SANDBOX" rev-parse 'refs/tags/handover/sep-identity/1^{commit}')
equal "$handover_commit" "$(git -C "$pwt" rev-parse HEAD)" 'the tag is at the branch tip'

# Work continues on the parent AFTER the point, which is the case that makes
# the point worth having: the child must not receive these, and must not
# submit them either.
#
# A different file from the one the child writes, deliberately. The parent
# touching the child's file after the point is an ordinary conflict and the
# queue reports it as one -- what is being tested here is the clean path,
# where the point does its job and nothing collides.
commit "$pdir" notes.md 'what is left' 'sep: note what the directories still need'

out=$(q . handover 'handover/sep-identity/1')
contains 'added to sep-identity after this point (1 commit)' "$out" \
    'show says what arrived after the point'
contains 'client-minted identity is done' "$out" "show prints the author's own words"

out=$(q . handover sep-identity/1)
contains 'handover/sep-identity/1' "$out" 'the name resolves without its prefix'

# --- a branch started from that point ------------------------------------

case_ 'a worktree based on the handover point'

out=$(q . worktree sep-edit-dirs --from handover/sep-identity/1)
cwt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
cdir=${cwt#"$SANDBOX"/}
contains 'from handover/sep-identity/1' "$out" 'the branch says where it started'
contains 'sep-identity -- in progress' "$out" 'and where that work stands'
equal "$(git -C "$cwt" rev-parse HEAD)" "$handover_commit" 'it starts at the point'
equal "$(cat "$cwt/identity.go")" minted 'it has the work below the point'
[ -e "$cwt/notes.md" ] && bad 'it does not have what came after' || ok 'it does not have what came after'
equal "$(git -C "$SANDBOX" rev-parse "refs/merge-queue-from/sep-edit-dirs")" \
    "$handover_commit" 'the branch point is recorded before any work'

commit "$cdir" edit.go 'real' 'sep: per-session edit directories'

# --- submitting, in the wrong order and then the right one ---------------

case_ 'the parent has to be in the queue first'

out=$(q_fail "$cdir" submit -m 'sep: per-session edit directories

Only the identity is minted per repo, so the edits need a directory per
session as well.') || true
contains 'sep-identity has not been submitted yet' "$out" 'submit refuses it'
contains 'handover/sep-identity/1' "$out" 'and names the point it is based on'
equal "$(q . list)" 'queue is empty' 'nothing was queued'

case_ 'the parent, then the child'

out=$(q "$pdir" submit -m 'sep: client-minted repo identity

The identity is minted on the client.')
contains 'queued sep-identity' "$out" 'the parent queues'
parent_id=$(q . list | awk 'NR==2 {print $1}')

out=$(q "$cdir" submit -m 'sep: per-session edit directories

Only the identity is minted per repo, so the edits need a directory per
session as well.')
contains 'queued sep-edit-dirs' "$out" 'the child queues'
contains 'based on handover/sep-identity/1' "$out" 'and says what it is based on'
contains 'only this branch' "$out" 'and that only its own commits went in'
child_id=$(q . list | awk 'NR==3 {print $1}')

equal "$(git -C "$SANDBOX" rev-parse "refs/merge-queue-base/$child_id/sep-edit-dirs")" \
    "$handover_commit" "the entry's base is the handover point"
equal "$(git -C "$SANDBOX" rev-list --count "$handover_commit..refs/heads/sep-edit-dirs")" \
    1 'so the entry is its own one commit'
git -C "$SANDBOX" show-ref --verify --quiet refs/merge-queue-from/sep-edit-dirs &&
    bad 'the declared base is consumed at submission' ||
    ok 'the declared base is consumed at submission'
[ "$parent_id" \< "$child_id" ] &&
    ok 'the child sorts behind the parent' ||
    bad 'the child sorts behind the parent' "$parent_id vs $child_id"

case_ 'the queue replays clean'
out=$(q . check)
contains 'the whole queue replays clean onto main' "$out" 'check is happy'

# --- draining: the squash, and what the point means afterwards -----------

case_ 'draining both, in order'

out=$(q . drain)
contains 'landed 2' "$out" 'both landed'
equal "$(git -C "$SANDBOX" rev-list --count main)" 3 'one commit on main per entry'
equal "$(git -C "$SANDBOX" log -1 --format=%s main)" 'sep: per-session edit directories' \
    'the child landed last'
equal "$(cat "$SANDBOX/edit.go")" real 'the child'"'"'s work is on main'
equal "$(cat "$SANDBOX/identity.go")" minted 'the parent'"'"'s work is on main'

case_ 'the handover point outlives the branch it was cut from'

git -C "$SANDBOX" show-ref --verify --quiet refs/heads/sep-identity &&
    bad 'the parent branch is gone' || ok 'the parent branch is gone'
equal "$(git -C "$SANDBOX" rev-parse 'refs/tags/handover/sep-identity/1^{commit}')" \
    "$handover_commit" 'the point still names the same commit'
equal "$(git -C "$SANDBOX" log -1 --format=%s "$handover_commit")" \
    'sep: test the minted identity' 'and that commit is still readable'
git -C "$SANDBOX" merge-base --is-ancestor "$handover_commit" main 2>/dev/null &&
    bad 'the squash means it is not an ancestor of main' ||
    ok 'the squash means it is not an ancestor of main'

out=$(q . handover)
contains 'landed on main as' "$out" 'so the listing answers it from the queue instead'

# --- the withdrawn case --------------------------------------------------

case_ 'a point on work that is withdrawn'

out=$(q . worktree sep-second)
swt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
sdir=${swt#"$SANDBOX"/}
commit "$sdir" second.go 'one' 'sep: the first half'
q "$sdir" handover -m 'the first half is done' >/dev/null
commit "$sdir" second2.go 'two' 'sep: the second half'

out=$(q . worktree sep-third --from handover/sep-second/1)
twt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
tdir=${twt#"$SANDBOX"/}
commit "$tdir" third.go 'three' 'sep: work on top of the first half'

q "$sdir" submit -m 'sep: the halves

Both halves.' >/dev/null
q "$tdir" submit -m 'sep: on top of the first half

Work on top of it.' >/dev/null

out=$(q_fail . drop sep-second) || true
contains 'has work stacked on top of it' "$out" 'drop refuses while work sits on it'
contains 'sep-third' "$out" 'and names what it would orphan'

FORCE_DROP=1 q . drop sep-second >/dev/null
out=$(q . status)
contains 'ORPHANED' "$out" 'the entry on top is orphaned by the withdrawal'
out=$(q_fail . merge sep-third) || true
contains 'ORPHANED' "$out" 'and merge refuses it'

# --- the guards on the command itself -----------------------------------

case_ 'what handover refuses'

out=$(q_fail . handover -m 'from the main checkout') || true
contains 'main needs no handover point' "$out" 'it refuses one on main'
out=$(q_fail "$tdir" handover -m '   ') || true
contains 'needs a message' "$out" 'it refuses one with nothing to say'
out=$(q_fail . handover 'handover/nope/1') || true
contains 'no handover point named' "$out" 'and an unknown name is an error'

case_ 'a branch point with no handover point on it'

out=$(q . worktree sep-fourth --from sep-third)
fwt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
fdir=${fwt#"$SANDBOX"/}
contains 'No handover point marks that commit' "$out" \
    'starting from a bare commit says what the queue cannot then do'
equal "$(git -C "$SANDBOX" rev-parse refs/merge-queue-from/sep-fourth)" \
    "$(git -C "$SANDBOX" rev-parse refs/heads/sep-third)" 'the base is still recorded'

commit "$fdir" fourth.go 'four' 'sep: a fourth thing'
q "$fdir" submit -m 'sep: a fourth thing

A fourth thing.' >/dev/null
fid=$(q . list | awk '$2 == "sep-fourth" {print $1}')
equal "$(git -C "$SANDBOX" rev-list --count "$(git -C "$SANDBOX" rev-parse refs/merge-queue-base/$fid/sep-fourth)..refs/heads/sep-fourth")" \
    1 'and the entry is still only its own commits'

# --- the one case where ids come out in the wrong order -----------------

case_ 'a parent whose worktree was made by hand, and so claims its id late'

# No `make queue-worktree`, so no id in the name and no id claimed: this
# branch claims one at SUBMISSION, which is after the child's. Merge order is
# id order, so without the guard the child would be merged first, onto a main
# that has not got what it was written against.
git -C "$SANDBOX" worktree add -q -b sep-byhand "$SANDBOX/.worktrees/by-hand" main
commit .worktrees/by-hand hand.go 'one' 'sep: by hand, the first half'
q .worktrees/by-hand handover -m 'the first half is done by hand' >/dev/null
commit .worktrees/by-hand hand2.go 'two' 'sep: by hand, the second half'

out=$(q . worktree sep-onhand --from handover/sep-byhand/1)
owt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
odir=${owt#"$SANDBOX"/}
child_claimed=$(basename "$owt")
commit "$odir" onhand.go 'three' 'sep: on top of the hand-made branch'

q .worktrees/by-hand submit -m 'sep: both halves by hand

Both halves.' >/dev/null
hand_id=$(q . list | awk '$2 == "sep-byhand" {print $1}')
[ "$child_claimed" \< "$hand_id" ] &&
    ok 'the parent did claim its id after the child'"'"'s worktree' ||
    bad 'the parent did claim its id after the child'"'"'s worktree' \
        "child worktree $child_claimed, parent entry $hand_id"

out=$(q "$odir" submit -m 'sep: on top of the hand-made branch

On top of it.' 2>&1)
contains 'takes a new id to stay behind it' "$out" 'submit says it is reordering'
onhand_id=$(q . list | awk '$2 == "sep-onhand" {print $1}')
[ "$hand_id" \< "$onhand_id" ] &&
    ok 'and the child ends up behind the parent after all' ||
    bad 'and the child ends up behind the parent after all' \
        "parent $hand_id, child $onhand_id"

# --- the id an agent stamps a review with --------------------------------

case_ 'a fresh id, for stamping something that is not an entry'

stamp=$(q . id)
case "$stamp" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9])
        ok 'it is in the queue id format' ;;
    *)  bad 'it is in the queue id format' "got: $stamp" ;;
esac

# The property `/branch-review` relies on: a stamp compares against entry ids
# as a string, so a review is datable against the queue it reviewed. A clock
# read later than every submission above must sort after the last of them.
[ "$onhand_id" \< "$stamp" ] &&
    ok 'and it sorts after the entries submitted before it' ||
    bad 'and it sorts after the entries submitted before it' \
        "last entry $onhand_id, stamp $stamp"

# It reads the clock and claims nothing -- the ref lock is `submit`'s business,
# and an id that named a non-existent entry would be worse than no id at all.
if git -C "$SANDBOX" show-ref --verify --quiet "refs/merge-queue-id/$stamp"; then
    bad 'and it claims no id ref' "refs/merge-queue-id/$stamp exists"
else
    ok 'and it claims no id ref'
fi

# --- the sessions that worked on an entry --------------------------------

case_ 'the sessions of an entry, and their audits'

# Transcripts in the shape Claude Code writes them, under a config dir of the
# sandbox's own: the main checkout's project, a subagent of one of its
# sessions, a worktree's project -- and two that must NOT be found, one that
# only mentions the id in a prompt and one whose command named another entry.
export CLAUDE_CONFIG_DIR=$SANDBOX/.claude
projects=$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$SANDBOX" | tr -c 'A-Za-z0-9' '-')
mkdir -p "$projects/s1/subagents" "$projects--worktrees-$child_id"
printf '{"type":"user","toolUseResult":{"stdout":"id        %s -- the name of the worktree"}}\n' \
    "$child_id" > "$projects/s1.jsonl"
printf '{"type":"user","toolUseResult":{"stdout":"","stderr":"queued sep-edit-dirs as %s"}}\n' \
    "$child_id" > "$projects/s1/subagents/agent-a.jsonl"
printf '{"type":"user","toolUseResult":{"stdout":"landed %s"}}\n' \
    "$child_id" > "$projects--worktrees-$child_id/s2.jsonl"
printf '{"type":"user","message":{"content":"look at %s"}}\n' "$child_id" > "$projects/s3.jsonl"
printf '{"type":"user","toolUseResult":{"stdout":"landed %s"}}\n' "$parent_id" > "$projects/s4.jsonl"

if command -v jq >/dev/null; then
    out=$(q . sessions sep-edit-dirs)
    equal "$out" "$projects--worktrees-$child_id/s2.jsonl
$projects/s1.jsonl
$projects/s1/subagents/agent-a.jsonl" \
        'a session, its subagent and a worktree session, and not a mere mention'
    equal "$(q . sessions main)" "$out" 'a commit on main finds its entry by the trailer'
    out=$(q_fail . sessions "$(git -C "$SANDBOX" rev-list --max-parents=0 main)") || true
    contains 'has no Queue: trailer' "$out" 'a commit that no entry landed is refused'
    out=$(q_fail . sessions sep-second) || true
    contains 'no transcript has a command whose output names' "$out" 'an entry no session names is refused'

    printf '#!/bin/sh\necho "chaland $*"\n' > "$CLAUDE_CONFIG_DIR/chaland"
    chmod +x "$CLAUDE_CONFIG_DIR/chaland"
    out=$(CHALAND=$CLAUDE_CONFIG_DIR/chaland q . audit "$parent_id" -limit 1m)
    contains "chaland audit -limit 1m $projects/s4.jsonl" "$out" 'audit runs chaland on each transcript, flags first'
    if ! command -v chaland >/dev/null; then
        out=$(CHALAND='' q_fail . audit "$parent_id") || true
        contains 'set CHALAND' "$out" 'and says how to name chaland when it is not on PATH'
    fi
else
    printf '  skip  jq is not on PATH, and sessions reads the transcripts with it\n'
fi
unset CLAUDE_CONFIG_DIR

# --- a repository whose trunk is not `main` ------------------------------

case_ 'a round trip on a repository whose trunk is master'

# QUEUE_MAIN is the only thing about the queue that names the target branch:
# the base a worktree branches from, what `status` compares against and what
# the drain fast-forwards all follow it. A short round trip here is what covers
# that substitution, rather than trusting that every one of them was caught.
MSANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/queue-test-master.XXXXXX")
MSANDBOX=$(cd "$MSANDBOX" && pwd -P)

git init -q -b master "$MSANDBOX"
git -C "$MSANDBOX" config user.email queue-test@example.com
git -C "$MSANDBOX" config user.name 'Queue Test'
git -C "$MSANDBOX" config commit.gpgsign false
printf 'start\n' > "$MSANDBOX/README"
git -C "$MSANDBOX" add README
git -C "$MSANDBOX" commit -q -m 'start'

# The same shape as `q`, in the other sandbox, with the target branch set.
mq() { local dir=$1; shift; ( cd "$MSANDBOX/$dir" && QUEUE_MAIN=master "$QUEUE" "$@" ); }

out=$(mq . worktree api-on-master)
contains 'from master,' "$out" 'the worktree branches from master'
mwt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
mdir=${mwt#"$MSANDBOX"/}

printf 'one\n' > "$MSANDBOX/$mdir/f.txt"
git -C "$MSANDBOX/$mdir" add f.txt
git -C "$MSANDBOX/$mdir" commit -q -m 'api: add f'

mq "$mdir" submit -m 'api: add f

A first entry, on a repository that never had a main.' >/dev/null

out=$(mq . status)
contains 'master ' "$out" 'status reports master as the target'

out=$(mq . check)
contains 'replaying the queue onto master' "$out" 'check replays onto master'

out=$(mq . drain)
contains 'draining onto master' "$out" 'the drain says what it drains onto'
contains 'landed 1' "$out" 'and it landed the entry'

equal "$(git -C "$MSANDBOX" log -1 --format=%s master)" 'api: add f' \
    'the squash commit is on master'
contains 'Queue: ' "$(git -C "$MSANDBOX" log -1 --format=%B master)" \
    'carrying the provenance trailer'
contains 'api-on-master' "$(git -C "$MSANDBOX" log -1 --format=%B master)" \
    'which names the branch it came from'
git -C "$MSANDBOX" show-ref --verify --quiet refs/heads/api-on-master &&
    bad 'the branch is gone' || ok 'the branch is gone'

out=$(mq . list)
contains 'queue is empty' "$out" 'and the queue is empty again'

# --- an entry its tests fail ----------------------------------------------

case_ 'an entry the tests fail is left pending, and lands once fixed'

# QUEUE_TEST runs on the entry's squashed tree, in the drain's scratch
# worktree, before the target branch moves. These "tests" fail while the tree
# has a file called broken.
tq() { local dir=$1; shift; ( cd "$MSANDBOX/$dir" && QUEUE_MAIN=master QUEUE_TEST='test ! -e broken' "$QUEUE" "$@" ); }

out=$(mq . worktree api-broken)
bwt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
bdir=${bwt#"$MSANDBOX"/}
printf 'oops\n' > "$MSANDBOX/$bdir/broken"
git -C "$MSANDBOX/$bdir" add broken
git -C "$MSANDBOX/$bdir" commit -q -m 'api: add g, broken'
mq "$bdir" submit -m 'api: add g

An entry its tests fail, until it is fixed.' >/dev/null
before=$(git -C "$MSANDBOX" rev-parse master)

out=$(tq . drain) || true
contains 'TESTS FAILED' "$out" 'the drain stops on the entry its tests fail'
equal "$(git -C "$MSANDBOX" rev-parse master)" "$before" 'and leaves master where it was'
contains 'api-broken' "$(mq . list)" 'and the entry pending'
[ -d "$MSANDBOX/.worktrees/.merge-queue" ] &&
    bad 'and lets go of the drain lock' || ok 'and lets go of the drain lock'

if out=$(tq . merge api-broken 2>&1); then
    bad 'merge refuses it too' "$out"
else
    contains 'failed test ! -e broken' "$out" 'merge refuses it too'
fi
equal "$(git -C "$MSANDBOX" rev-parse master)" "$before" 'and leaves master where it was'

git -C "$MSANDBOX/$bdir" rm -q broken
printf 'g\n' > "$MSANDBOX/$bdir/g.txt"
git -C "$MSANDBOX/$bdir" add g.txt
git -C "$MSANDBOX/$bdir" commit -q -m 'api: add g, not broken'

out=$(tq . drain)
contains 'landed 1' "$out" 'once fixed, it lands'
contains ', tested' "$out" 'having been tested'
equal "$(git -C "$MSANDBOX" show master:g.txt)" g 'with its fix'

# --- the tooling has to be committed, not just installed -----------------

case_ 'a repository where the queue is installed but not committed'

# The only case that runs the script from INSIDE the repository it drives,
# because that is what makes the question askable: a worktree checks out a
# commit, so tooling that is in the working tree and not in that commit is
# absent from the worktree, and the failure lands later and somewhere else.
# Everywhere above, the script lives outside the sandbox, no commit of the
# sandbox was ever meant to carry it, and the check stays out of the way.
ISANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/queue-test-install.XXXXXX")
ISANDBOX=$(cd "$ISANDBOX" && pwd -P)

git init -q -b main "$ISANDBOX"
git -C "$ISANDBOX" config user.email queue-test@example.com
git -C "$ISANDBOX" config user.name 'Queue Test'
git -C "$ISANDBOX" config commit.gpgsign false
printf 'start\n' > "$ISANDBOX/README"
git -C "$ISANDBOX" add README
git -C "$ISANDBOX" commit -q -m 'start'
first=$(git -C "$ISANDBOX" rev-parse HEAD)

mkdir -p "$ISANDBOX/queue"
cp "$QUEUE" "$ISANDBOX/queue/queue.sh"
cp "$(dirname "$QUEUE")/queue.mk" "$ISANDBOX/queue/queue.mk"

# The installed copy, which is the one whose location is the point.
iq() { local dir=$1; shift; ( cd "$ISANDBOX/$dir" && "$ISANDBOX/queue/queue.sh" "$@" ); }
iq_fail() {
    local dir=$1 out rc=0; shift
    out=$( cd "$ISANDBOX/$dir" && "$ISANDBOX/queue/queue.sh" "$@" 2>&1 ) || rc=$?
    printf '%s\n' "$out"
    [ "$rc" != 0 ]
}

if out=$(iq_fail . worktree api-uncommitted); then
    contains 'has no queue tooling' "$out" 'a worktree off an uncommitted install is refused'
    contains 'queue/queue.sh queue/queue.mk' "$out" 'naming what the commit has not got'
    contains 'git -C' "$out" 'and the commit that fixes it'
else
    bad 'a worktree off an uncommitted install is refused' "$out"
fi

[ -d "$ISANDBOX/.worktrees" ] &&
    bad 'and nothing was created' || ok 'and nothing was created'
git -C "$ISANDBOX" show-ref --verify --quiet refs/heads/api-uncommitted &&
    bad 'no branch either' || ok 'no branch either'
equal "$(git -C "$ISANDBOX" for-each-ref --count=1 refs/merge-queue-id)" '' \
    'and no id was spent on it'

# Ignoring the tooling is a decision to carry it outside git, and the check
# stands aside for it rather than leaving that repository unable to start work.
printf 'queue/\n' > "$ISANDBOX/.gitignore"
git -C "$ISANDBOX" add .gitignore
git -C "$ISANDBOX" commit -q -m 'build: keep the queue out of git'
out=$(iq . worktree api-ignored)
contains 'worktree  ' "$out" 'a repository that ignores the tooling is left alone'
iwt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
git -C "$ISANDBOX" worktree remove --force "$iwt"
git -C "$ISANDBOX" branch -q -D api-ignored

git -C "$ISANDBOX" rm -q --cached .gitignore
printf '' > "$ISANDBOX/.gitignore"
git -C "$ISANDBOX" add -A queue .gitignore
git -C "$ISANDBOX" commit -q -m 'build: install the merge queue'

out=$(iq . worktree api-committed)
iwt=$(printf '%s\n' "$out" | sed -n 's/^worktree  *//p')
[ -x "$iwt/queue/queue.sh" ] &&
    ok 'once committed, the worktree gets the tooling' ||
    bad 'once committed, the worktree gets the tooling' "$iwt"

# A point taken before the install is the same absence, arrived at the other
# way round, and it needs the other half of the message: a rebase, not a commit.
if out=$(iq_fail . worktree api-old --from "$first"); then
    contains 'predates the install' "$out" \
        'and a branch off a pre-install commit is refused too'
else
    bad 'and a branch off a pre-install commit is refused too' "$out"
fi

# ---------------------------------------------------------------------------

printf '\n%s checks, %s failed\n' "$checks" "$failures"
[ -z "${KEEP:-}" ] ||
    printf 'sandboxes kept: %s %s %s\n' "$SANDBOX" "$MSANDBOX" "$ISANDBOX"
[ "$failures" = 0 ]
