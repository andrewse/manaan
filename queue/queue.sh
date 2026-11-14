#!/usr/bin/env bash
#
# The merge queue. A worktree whose work is finished is SUBMITTED here, and a
# dedicated agent drains the queue into main in submission order.
#
# The queue is git refs, not a file. Three reasons:
#
#   - A ref pins a commit, so a worktree that is deleted does not take the
#     entry with it: the submitted commit stays reachable through the ref.
#   - Refs live in the common .git directory, shared by every worktree. A
#     submission made from .worktrees/foo is visible to the agent draining the
#     queue in the main checkout, with no file to find or lock.
#   - Nothing to garbage-collect by hand: the commit stays reachable while the
#     entry exists, which is the whole window in which it matters.
#
#   refs/merge-queue/<id>/<branch>          pending, lowest <id> merges first
#   refs/merge-queue-done/<id>/<branch>     merged into main
#   refs/merge-queue-dropped/<id>/<branch>  withdrawn without merging
#   refs/merge-queue-base/<id>/<branch>     what it was written against
#   refs/merge-queue-msg/<id>/<branch>      the message its squash commit takes
#   refs/merge-queue-from/<branch>          a branch point declared before the work
#   refs/tags/handover/<branch>/<n>         a branch point other work may start from
#
# The first three are states, and an entry only ever leaves `pending` for one
# of the two terminal ones. `base` and `msg` are attributes rather than states:
# they are written once and outlive both, because "what did that entry
# contribute, and what did it say it was doing" is asked long after it landed.
#
# A HANDOVER POINT is the last two, and it exists because a sha is not a usable
# branch point here. Work that needs what another branch has half-finished has
# to start from a commit on that branch -- and when that branch lands, the
# drain squashes its commits into one and deletes it, so the sha a handover
# document quoted names nothing any reader can reach. A handover document then
# cannot say "start here"; it has to say "inspect the queue and work out
# whether this is on main yet", which is a question the next agent should never
# have been handed.
#
# An annotated tag fixes exactly that and nothing else: it pins the commit, so
# the commit and its ancestors stay reachable through the squash and through
# the branch deletion, and it is a name rather than a sha, so it can be written
# into a document. The tag's message is where the author says what is finished
# at that point, which is the other half of the handover.
#
# `handover` creates one; `worktree --from <tag>` starts a branch there and
# records the commit as that branch's declared base, in `refs/merge-queue-from`,
# before any work happens. `submit` reads it back, so the entry's base is the
# handover point rather than main -- and the entry therefore submits only its
# OWN commits, exactly as a stack submitted off a parent's tip does.
#
# Whether the work BELOW a handover point is on main cannot be answered by
# ancestry: the squash rewrote it, so the handover commit is never an ancestor
# of main no matter how long ago its branch landed. It is a queue question, and
# it is answered twice -- by the done ref locally, and by the `Queue:` trailer
# on main's own commit, which is the only one of the two a clone has.
#
# The MESSAGE is written by the author, at submission, and is not optional. The
# drain squashes the entry's commits into a single commit on main and takes
# that commit's message from here -- so main reads as one commit per entry,
# each one describing a change rather than a step towards it. The author is the
# one who knows what the change does; the drain only knows what conflicted.
# This is what replaced CHANGELOG.md: main's log IS the changelog now, which is
# why `submit` refuses an entry that has no message.
#
# <id> is a UTC timestamp to the microsecond, 20261013T094402.118293. It is a
# timestamp and not a counter because a counter has to be ALLOCATED: read the
# highest in use, add one, write it back. Two submissions racing through that
# read-modify-write both get the same number, and then the queue has two
# entries with one name and no defined order between them -- which inverts the
# one guarantee the queue exists to provide. A timestamp is not allocated, it
# is simply read, so there is no window to race in. Ordering is lexicographic,
# which for this format is also chronological, and which keeps the four-digit
# counters from the queue's first dozen entries sorted ahead of every timestamp.
#
# The id can be claimed BEFORE the work: `worktree` claims one and names the
# worktree after it, and `submit` then reuses the id its worktree carries
# instead of claiming another. That is for the name, not the queue -- a
# worktree name used to be invented by whoever was about to do the work, and
# two agents working at once can invent the same one, while an id cannot
# collide by construction. `refs/merge-queue-id/<id>` is what makes a claim a
# claim, so it is also how `submit` tells a real id from a directory that
# merely looks like one. An id claimed and never submitted stays claimed; it
# costs one ref and keeps the microsecond it names from ever being reused.
#
# The base ref is written at submission and never moves. Without it, asking an
# already-merged entry what it contributed gives nothing: the submitted commit
# is an ancestor of main by then, so `git merge-base main <sha>` returns <sha>
# itself and the range collapses to empty. The answer has to be recorded while
# it is still true.
#
# The drain merges the branch TIP, not the commit that was pinned at
# submission. Pinning read better -- the entry was a fixed thing -- but it made
# the drain's own cleanup destructive: it deletes the branch when it is done,
# and anything committed after submitting was then deleted with it, unreachable
# and not in any reflog. Submitting and then committing one more fix is far too
# ordinary to punish that way. The pinned commit is still recorded, is still
# what `show` and `log` report, and is still what gets merged when the branch
# has since been deleted -- the ref is the only thing keeping it reachable.

set -euo pipefail

PENDING_NS=refs/merge-queue
DONE_NS=refs/merge-queue-done
DROPPED_NS=refs/merge-queue-dropped
BASE_NS=refs/merge-queue-base
MSG_NS=refs/merge-queue-msg
ID_NS=refs/merge-queue-id
FROM_NS=refs/merge-queue-from
HANDOVER_NS=handover

# The branch the queue merges into. Everything about the queue is relative to
# it: the base a worktree branches from, what `status` compares against, and
# what the drain fast-forwards. The refs/merge-queue* namespaces do not carry
# the branch name, so nothing about the ref layout depends on this.
MAIN=${QUEUE_MAIN:-main}

# A command the drain runs on each entry's squashed tree, in its scratch
# worktree, before the target branch moves to it -- the repository's fast
# tests. An entry that fails it is left pending, as one that conflicts is, so
# everything that lands has passed it. Empty, the default, runs nothing. Set it
# in the including Makefile, before the include:
#     QUEUE_TEST := make test-unit
TEST=${QUEUE_TEST:-}

# How to tell the reader to invoke us. Every hint this script prints is built
# from this, so a target repo that drives the queue with something other than
# the shipped Makefile sets QUEUE_CLI and the hints follow it. Only the command
# WORD follows it -- the argument syntax in a hint is the Makefile's
# (BRANCH=, ENTRY=, M= in the environment) and cannot be varied by a prefix.
CLI=${QUEUE_CLI:-make queue-}

die() { printf 'queue: %s\n' "$*" >&2; exit 1; }

# Whether a string is a queue id. Asked of the clock's output below, and of
# strings that came from somewhere else -- the basename of the worktree a
# submission is standing in.
is_queue_id() {
    case "${1:-}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# Which state an id already names, if any: pending, merged or dropped. Empty
# means the id has been claimed but never spent on an entry, which is what a
# worktree waiting to be submitted looks like.
id_state() {
    local id=$1 ns state
    for ns in "$PENDING_NS" "$DONE_NS" "$DROPPED_NS"; do
        case "$ns" in
            "$PENDING_NS") state=pending ;;
            "$DONE_NS")    state=merged ;;
            *)             state=dropped ;;
        esac
        if [ -n "$(git for-each-ref --format='%(refname)' "$ns/$id")" ]; then
            printf '%s\n' "$state"
            return
        fi
    done
}

# A queue id: UTC, to the microsecond. See the header for why this is not a
# counter. The format is checked rather than trusted because a date(1) without
# %N support would yield a literal "%N" and quietly produce ids that neither
# sort nor round-trip.
#
# Reading the clock is all this does, so it is also what names anything else
# that has to be unique per run without being coordinated -- `check`'s scratch
# worktree. `claim_id` is the version that takes the id as well.
new_id() {
    local id
    id=$(date -u +%Y%m%dT%H%M%S.%N)
    id=${id:0:22}
    is_queue_id "$id" || die "cannot build a queue id from date(1): got '$id'"
    printf '%s\n' "$id"
}

# CLAIMED, not merely generated. A timestamp needs no read-modify-write, so it
# cannot race the way a counter does, but two submissions in the same
# microsecond would still land on the same id -- and "check whether that id is
# taken, then take it" is the same race in miniature, because both submissions
# check before either writes. So the id is claimed by creating a ref with git's
# own must-not-exist precondition: `update-ref <ref> <sha> ''` fails if <ref>
# is already there, and git takes a lock to decide. First claimer wins, the
# loser reads the clock again and claims the next one.
claim_id() {
    local sha=$1 id tries=0
    while :; do
        id=$(new_id)
        if git update-ref "$ID_NS/$id" "$sha" '' 2>/dev/null; then
            printf '%s\n' "$id"
            return
        fi
        tries=$(( tries + 1 ))
        [ "$tries" -lt 100 ] || die "could not claim a queue id after $tries attempts"
    done
}

# The first line of a stream, without a pipe into head(1).
#
# `... | head -1` closes the pipe as soon as it has its line, and the producer
# still writing then dies of SIGPIPE -- which `pipefail` turns into a failed
# pipeline and `set -e` turns into a dead script. It only happens when there is
# more than one line to produce, which is exactly the interesting case.
first_line() {
    local out
    out=$(cat)
    [ -z "$out" ] || printf '%s\n' "${out%%$'\n'*}"
}

# Where a drain keeps its scratch worktree. Its existence IS the drain lock:
# the second drain to try to create it fails, which is what stops two agents
# merging at once, and `drop` refuses while it is there. A drain that died
# leaves it behind, which `status` reports as a blocker.
drain_lock() { printf '%s/.worktrees/.merge-queue\n' "$(main_checkout)"; }
drain_in_progress() { [ -d "$(drain_lock)" ]; }

# Scratch worktrees left behind by a check that was killed outright. Reported,
# never removed: a check's worktree is named per run rather than fixed, so the
# only way to tell a dead one from a live one is to look, and force-removing
# what merely looks dead is the exact bug the per-run name exists to fix.
# Harmless to leave -- nothing reads them and the next check builds its own.
stale_checks() {
    local mc=$1 found
    found=$(git worktree list --porcelain |
            sed -n "s|^worktree $mc/.worktrees/\(\.queue-check-.*\)$|\1|p") || true
    [ -n "$found" ] || return 0
    printf 'queue: scratch worktrees from a check that did not finish:\n' >&2
    printf '%s\n' "$found" | sed 's|^|    .worktrees/|' >&2
    printf 'queue: left alone -- one may belong to a check running now. To clear one:\n' >&2
    printf '           git worktree remove --force .worktrees/<name>\n\n' >&2
}

# Entries in one namespace as TAB-separated id, branch, sha -- in merge order.
# Branch names may contain '/', so the branch is everything after the id.
#
# Lexicographic, NOT numeric: `sort -n` reads 20261013T094402.118293 as the
# number 20261013 and throws away everything that distinguishes two
# submissions in the same day.
entries() {
    local ns=$1 refname sha rest
    git for-each-ref --format='%(refname) %(objectname)' "$ns" |
    while read -r refname sha; do
        rest=${refname#"$ns"/}
        printf '%s\t%s\t%s\n' "${rest%%/*}" "${rest#*/}" "$sha"
    done | sort -k1,1
}

# The pending entry for a branch, or nothing.
pending_for_branch() {
    entries "$PENDING_NS" | awk -F'\t' -v b="$1" '$2 == b'
}

# The pending entry matching an id, a unique id PREFIX, or a branch name.
#
# Ids are long enough that nobody should have to type one in full, so a prefix
# resolves the way a short sha does. An ambiguous prefix is an error rather
# than a silent choice between two entries -- picking one would be picking
# which piece of work to act on by accident.
pending_for_id() {
    local want=$1 hits
    hits=$(entries "$PENDING_NS" |
           awk -F'\t' -v w="$want" '$1 == w || $2 == w || index($1, w) == 1')
    case "$(printf '%s' "$hits" | grep -c . || true)" in
        0) ;;
        1) printf '%s\n' "$hits" ;;
        *) die "$(printf "'%s' matches %s pending entries:\n%s" "$want" \
                  "$(printf '%s' "$hits" | grep -c .)" \
                  "$(printf '%s' "$hits" | awk -F'\t' '{printf "    %s  %s\n", $1, $2}')")" ;;
    esac
}

# The pending entry this branch is STACKED ON, if any -- the highest-numbered
# one whose submitted commit is already an ancestor of this branch.
#
# Work written on top of work that has not landed yet is a real and reasonable
# thing to do: 0002 needed what 0001 added. But then 0001's commits are part of
# 0002's branch too, and basing 0002 on main would submit them twice -- the
# drain replays 0001, then replays 0002 including its copy of 0001, and the
# second copy conflicts with the first. Basing on the parent entry's tip
# instead submits only this branch's own commits.
stacked_on() {
    local sha=$1 id branch s
    entries "$PENDING_NS" | while IFS=$'\t' read -r id branch s; do
        if [ "$s" != "$sha" ] && git merge-base --is-ancestor "$s" "$sha" 2>/dev/null; then
            printf '%s\t%s\t%s\n' "$id" "$branch" "$s"
        fi
    done | tail -1
}

# The pending entry this one sits on top of, if any: the highest-numbered OTHER
# pending entry whose submitted commit is already in this branch.
#
# Asked of a branch about to be merged on its own, the question is "is anything
# still in the queue underneath this". It is deliberately not "is its base on
# main": a stacked entry's base is its parent's PRE-rebase tip, the parent's own
# landing squashed those commits away, and so the base of a correctly stacked
# entry is never on main even once its parent has landed perfectly. Testing for
# that would block exactly the case it is meant to allow -- the same trap
# `orphaned_by` documents.
pending_under() {
    local tip=$1 me=$2 id branch s
    entries "$PENDING_NS" | while IFS=$'\t' read -r id branch s; do
        if [ "$id" != "$me" ] && git merge-base --is-ancestor "$s" "$tip" 2>/dev/null; then
            printf '%s\t%s\n' "$id" "$branch"
        fi
    done | tail -1
}

# Pending entries written on top of this one. These are what a withdrawal
# would orphan.
#
# Two ways to be written on top of an entry, so two tests. The base is this
# entry's submitted commit -- a branch started from its tip. Or the base is a
# HANDOVER POINT cut from this entry's branch, which is a commit in the middle
# of it and so equals no entry's tip at all; the tag's name is what says whose
# branch it is. Only the first test existed, and a withdrawal therefore
# orphaned every handover child in silence.
#
# The branch is optional so that callers which only have a sha keep working;
# without it, only the first test can be made.
pending_children_of() {
    local sha=$1 want_branch=${2:-} id branch s base tag
    entries "$PENDING_NS" | while IFS=$'\t' read -r id branch s; do
        [ "$branch" != "$want_branch" ] || continue
        base=$(entry_base "$id" "$branch" "$s")
        if [ "$base" = "$sha" ]; then
            printf '%s\t%s\n' "$id" "$branch"
            continue
        fi
        [ -n "$want_branch" ] && [ -n "$base" ] || continue
        tag=$(handover_at "$base")
        if [ -n "$tag" ] && [ "$(handover_branch "$tag")" = "$want_branch" ]; then
            printf '%s\t%s\n' "$id" "$branch"
        fi
    done
}

# ---------------------------------------------------------------------------
# Handover points
#
# A tag at a commit on a branch still being worked on, so that other work can
# start from it and say so in writing. See the header for why a tag rather than
# the sha a handover document used to quote.
# ---------------------------------------------------------------------------

# The handover tag at a commit, if there is one. `--points-at` peels an
# annotated tag, so this answers for the commit the tag was made at.
#
# Two tags can sit on one commit -- the same point handed to two sessions, or a
# point tagged twice -- and the highest-numbered is taken, since the numbers
# only go up and so the later message is the one written with the most known.
handover_at() {
    # Decorated with the trailing number and sorted on that, rather than
    # `sort -t/ -k3`: a branch name may contain '/', and then the number is
    # not the third field and the sort is on part of the branch name instead.
    git tag --list "$HANDOVER_NS/*" --points-at "$1" 2>/dev/null |
        sed 's|.*/\([0-9]*\)$|\1\t&|' | sort -k1,1n | cut -f2- | tail -1
}

# The branch a handover tag was cut from, read out of the tag's own name:
# handover/<branch>/<n>. Branch names may contain '/', so the number is
# everything after the LAST slash and the branch is everything before it.
#
# The name is the whole of the linkage, deliberately. An id written into the
# tag would be the worktree's id at the time, and `submit` does not always
# spend that id on the entry -- while the branch is what every namespace here
# is keyed by alongside the id, and what `find_entry` already resolves in all
# three states. The cost is that a branch name reused by later work resolves to
# the live entry rather than the one the tag was cut from; `find_entry`
# searches pending first, which makes that the newer of the two.
handover_branch() {
    local rest=${1#"$HANDOVER_NS"/}
    printf '%s\n' "${rest%/*}"
}

# The next number for a branch's handover points, counted from the tags that
# exist rather than from a counter kept somewhere. Nothing has to be held in
# step, and a deleted tag's number is simply reused.
handover_next_seq() {
    local branch=$1 highest
    highest=$(git tag --list "$HANDOVER_NS/$branch/*" |
              sed "s|^$HANDOVER_NS/$branch/||" | sort -n | tail -1)
    printf '%s\n' "$(( ${highest:-0} + 1 ))"
}

# A handover tag named loosely: with the `handover/` prefix or without it,
# because a reader copying one out of a document will type it either way.
handover_resolve() {
    local want=$1 name
    for name in "$want" "$HANDOVER_NS/$want"; do
        if git show-ref --verify --quiet "refs/tags/$name"; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    return 1
}

# Where the work BELOW a base stands, when that base is a handover point:
# TAB-separated state, id, branch and tag. The state is that branch's queue
# entry -- pending, merged or dropped -- or `unsubmitted` when the branch has
# no entry at all, which is the ordinary case of a session still working.
#
# Empty output means the base is not a handover point and the question belongs
# to someone else: a base on main is not stacked on anything, and a base that
# is another entry's submitted tip is the stack `stacked_on` already handles.
handover_parent() {
    local base=$1 tag
    [ -n "$base" ] || return 0
    tag=$(handover_at "$base")
    [ -n "$tag" ] || return 0
    printf '%s\t%s\n' "$(handover_entry "$tag")" "$tag"
}

# The queue entry for the branch a handover tag was cut from, as TAB-separated
# state, id and branch -- or `unsubmitted` and no id, for a branch that has not
# reached the queue. Asked of the TAG rather than of a commit, because that is
# what a listing has in hand.
handover_entry() {
    local tag=$1 branch entry state id b
    branch=$(handover_branch "$tag")
    entry=$(find_entry "$branch" | first_line)
    if [ -z "$entry" ]; then
        # `-` and not an empty field. These records are read with `read -r`,
        # and bash collapses two adjacent tabs into one delimiter -- an empty
        # column in the middle silently shifts every column after it, which
        # reads as a branch called `handover/...` and a state that belongs to
        # nothing. A branch with no entry has no id, so the placeholder says so.
        printf 'unsubmitted\t-\t%s\n' "$branch"
        return 0
    fi
    IFS=$'\t' read -r state id b _ <<<"$entry"
    printf '%s\t%s\t%s\n' "$state" "$id" "$b"
}

# What to say about an entry started from work main has not got. Takes
# `waiting_on`'s record and names the point, the branch and where it stands,
# because all three are needed to decide what to do about it.
waiting_report() {
    local state id branch tag
    IFS=$'\t' read -r state id branch tag <<<"$1"
    printf 'started from %s (%s)\n' "$tag" \
        "$(handover_state_line "$state" "$id" "$branch")"
}

# Where an entry sits in the merge order, as "2 of 5".
queue_position() {
    local id=$1 total ahead
    total=$(entries "$PENDING_NS" | grep -c . || true)
    ahead=$(entries "$PENDING_NS" | awk -F'\t' -v i="$id" '$1 < i' | grep -c . || true)
    printf '%s of %s\n' "$(( ahead + 1 ))" "$total"
}

# One line saying where the work below a handover point stands, for a reader
# deciding whether they can start from it -- or, later, whether they can land
# on top of it. Takes `handover_parent`'s first three fields.
#
# `merged` names the commit on main rather than saying merely that it landed,
# because that commit is the answer to the question the sha could not answer:
# the squash means the handover commit is not an ancestor of main, so "is this
# work there" is read out of the `Queue:` trailer, which is also all a clone
# has.
handover_state_line() {
    local state=$1 id=$2 branch=$3 landed
    case "$state" in
        unsubmitted)
            printf '%s -- in progress, not submitted yet\n' "$branch" ;;
        pending)
            printf '%s -- pending as %s, %s in the queue\n' \
                "$branch" "$id" "$(queue_position "$id")" ;;
        merged)
            landed=$(landed_commit "$id")
            if [ -n "$landed" ]; then
                printf "%s -- landed on $MAIN as %s\n" \
                    "$branch" "$(git rev-parse --short "$landed")"
            else
                printf "%s -- merged as %s; $MAIN does not name it\n" "$branch" "$id"
            fi ;;
        dropped)
            printf '%s -- WITHDRAWN as %s\n' "$branch" "$id" ;;
    esac
}

# Why an entry based on a handover point cannot land yet, if it cannot:
# `handover_parent`, narrowed to the two states that block. `pending`, because
# that entry has to land first and the squash it lands as is what this entry's
# commits will sit on. `unsubmitted`, because an entry whose parent is not in
# the queue has nothing to be ordered behind -- it would replay onto a main
# that never receives what it was written against, cleanly and wrongly, which
# is the same breakage an orphan brings.
#
# Empty output is the good case, and it includes the one that matters most: a
# parent that has already merged. Its work is on main as a squash, so this
# entry's own commits replay onto it and nothing about this entry has to change.
waiting_on() {
    local parent state
    parent=$(handover_parent "$1")
    [ -n "$parent" ] || return 0
    state=${parent%%$'\t'*}
    case "$state" in
        pending|unsubmitted) printf '%s\n' "$parent" ;;
    esac
}

# The WITHDRAWN entry that this entry was written on top of, if any. Its
# existence is what "orphaned" means: the work below this entry was taken out
# of the queue, so replaying this entry alone puts commits on main that were
# written against code main has never seen.
#
# The obvious test for this is `git merge-base --is-ancestor <base> main`, and
# it is wrong. A legitimately stacked entry has its parent's PRE-rebase tip as
# its base, and the parent's own landing rewrote those commits -- so the base
# of every correctly-stacked entry fails that test too, and the guard would
# block exactly the case it is meant to permit. Membership of the dropped
# namespace is the real question, and it is the one asked here.
orphaned_by() {
    local base=$1 id branch s parent state
    [ -n "$base" ] || return 0
    # A handover base is a commit in the MIDDLE of the branch it came from, so
    # it equals no entry's submitted tip and the loop below cannot see it. The
    # tag names the branch, the branch resolves to the entry, and a withdrawn
    # one orphans this base exactly as a withdrawn tip does.
    parent=$(handover_parent "$base")
    if [ -n "$parent" ]; then
        IFS=$'\t' read -r state id branch _ <<<"$parent"
        [ "$state" != dropped ] || printf '%s\t%s\n' "$id" "$branch"
        return 0
    fi
    # An `if`, not `[ ... ] && printf`. The loop body's last command is the
    # loop's exit status, and with `pipefail` a final iteration that does not
    # match would make this whole function return 1 -- which, assigned into a
    # variable under `set -e`, kills the caller for finding nothing.
    entries "$DROPPED_NS" | while IFS=$'\t' read -r id branch s; do
        if [ "$s" = "$base" ]; then
            printf '%s\t%s\n' "$id" "$branch"
        fi
    done | first_line
}

# What to merge and from where, as TAB-separated base and tip.
#
# The tip is the BRANCH, so a commit added after submitting still lands rather
# than being deleted with the branch; it falls back to the submitted commit
# once the branch is gone, which is when the ref is the only thing holding it.
#
# The base is the recorded one, unless the branch has been rebased since it was
# submitted -- then the recorded base is no longer an ancestor of the tip and
# the range between them means nothing, so it is worked out again from where
# the branch now stands.
#
# A rebase onto a newer main does not do that: the recorded base is still an
# ancestor, and the range from it takes in everything that landed in between,
# which the drain would then replay a second time. So the base also moves up to
# the branch's merge-base with main whenever that is further along. A stacked
# entry's base is its parent's tip, which is not on main, so it never moves --
# and a stacked branch that MERGED main in is still replayed with main's
# commits in it.
entry_range() {
    local id=$1 branch=$2 sha=$3 base tip parent onmain
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        tip=$(git rev-parse "refs/heads/$branch")
    else
        tip=$sha
    fi
    base=$(entry_base "$id" "$branch" "$sha")
    if [ -n "$base" ] && ! git merge-base --is-ancestor "$base" "$tip" 2>/dev/null; then
        parent=$(stacked_on "$tip")
        if [ -n "$parent" ]; then
            base=$(printf '%s' "$parent" | cut -f3)
        else
            base=$(git merge-base "$MAIN" "$tip" 2>/dev/null || true)
        fi
    elif [ -n "$base" ]; then
        onmain=$(git merge-base "$MAIN" "$tip" 2>/dev/null || true)
        if [ -n "$onmain" ] && [ "$onmain" != "$base" ] &&
           git merge-base --is-ancestor "$base" "$onmain" 2>/dev/null; then
            base=$onmain
        fi
    fi
    printf '%s\t%s\n' "$base" "$tip"
}

# The checkout a branch is open in, if any.
worktree_for_branch() {
    git worktree list --porcelain |
    awk -v b="refs/heads/$1" '
        /^worktree /  { path = substr($0, 10) }
        /^branch /    { if (substr($0, 8) == b) { print path; exit } }'
}

# An entry's merge message: the message the drain gives the squash commit it
# puts on main.
#
# A ref pointing at a BLOB, not a commit. The message is text that has no
# parent, tree, author or date worth inventing, and a blob is exactly that.
# Anything outside refs/heads may point at any object, the ref keeps it from
# being garbage-collected while the entry exists, and `git cat-file blob` reads
# it back verbatim -- which matters, because this text becomes a commit message
# character for character.
msg_ref() { printf '%s/%s/%s\n' "$MSG_NS" "$1" "$2"; }

store_msg() {
    local id=$1 branch=$2 text=$3
    git update-ref "$(msg_ref "$id" "$branch")" \
        "$(printf '%s\n' "$text" | git hash-object -w --stdin)"
}

# Empty, and status 0, when there is no message recorded. An entry submitted
# before messages existed simply has none, and that is a fact about it rather
# than an error in reading it.
load_msg() {
    local ref
    ref=$(msg_ref "$1" "$2")
    git show-ref --verify --quiet "$ref" || return 0
    git cat-file blob "$ref"
}

# The merge message an entry lands under: the author's, with the queue's own
# provenance appended as a trailer.
#
# Nothing on main used to say which of its commits came through the queue. The
# squash is an ordinary commit, and everything the queue knows about the entry
# behind it lives in a ref keyed by `<id>/<branch>` -- none of which is ever
# pushed. So the record existed only on the machine that did the merge, and
# reading main told you nothing. The trailer is on the commit itself, which
# makes it the one piece of provenance that travels with the history.
#
# One line rather than a key per fact, because the id and the branch are the
# key to every other namespace -- the base it was written against, the message,
# the commits that were squashed -- so that pair plus the submitted sha is the
# whole of what cannot be worked out again, and main's log stays something a
# person reads rather than a form they fill in.
#
# The SUBMITTED sha, not the tip that was merged: the rebase rewrote it and the
# squash left it off main, so it is the one of the two that nothing else on main
# records. `show` prints both.
#
# `interpret-trailers` rather than appending the line by hand. It works out
# where the trailer block starts, so a message that already ends in one gets
# this added to that block instead of opening a second, and it handles a
# subject with no body and a body with no trailing newline, both of which
# authors write.
landing_msg() {
    local id=$1 branch=$2 sha=$3
    load_msg "$id" "$branch" |
        git interpret-trailers \
            --trailer "Queue: $id $branch $(git rev-parse --short "$sha")"
}

# Said once at submission and again whenever the message is replaced, because
# both are moments when it can still be fixed cheaply. Warnings, not refusals:
# the shape of a commit message is a convention worth holding to, and not one
# worth blocking finished work over.
warn_msg_shape() {
    local text=$1 subject second
    subject=$(printf '%s\n' "$text" | sed -n 1p)
    second=$(printf '%s\n' "$text" | sed -n 2p)
    [ "${#subject}" -le 72 ] ||
        printf 'queue: note: the subject is %s characters; 72 is the outside\n' \
            "${#subject}" >&2
    [ -z "$second" ] ||
        printf 'queue: note: line 2 is not blank, so git reads the whole message as the subject\n' >&2
}

# What an entry says it does, for a one-line listing: its merge message's
# subject, falling back to the submitted commit's for an entry that predates
# messages. The entry's own description beats its first commit's, which is a
# step towards the change rather than the change itself.
entry_subject() {
    local subject
    subject=$(load_msg "$1" "$2" | first_line)
    [ -n "$subject" ] || subject=$(git log -1 --format=%s "$3")
    printf '%s\n' "$subject"
}

cmd_list() {
    local id branch sha
    if [ -z "$(entries "$PENDING_NS")" ]; then
        echo "queue is empty"
        return
    fi
    printf '%-23s %-28s %-9s %s\n' ID BRANCH COMMIT MESSAGE
    entries "$PENDING_NS" | while IFS=$'\t' read -r id branch sha; do
        printf '%-23s %-28s %-9s %s\n' \
            "$id" "$branch" "$(git rev-parse --short "$sha")" \
            "$(entry_subject "$id" "$branch" "$sha")"
    done
}

# Both terminal states, interleaved in queue order, because "what happened to
# that entry" is the question this answers and "nothing, it was withdrawn" is one of
# the possible answers.
cmd_log() {
    local id branch sha state
    {
        entries "$DONE_NS"    | sed 's/$/\tmerged/'
        entries "$DROPPED_NS" | sed 's/$/\tdropped/'
    } | sort -k1,1 | while IFS=$'\t' read -r id branch sha state; do
        printf '%-23s %-9s %-28s %-9s %s\n' \
            "$id" "$state" "$branch" "$(git rev-parse --short "$sha")" \
            "$(entry_subject "$id" "$branch" "$sha")"
    done
}

# The head of the queue, TAB-separated:
#   id, branch, submitted sha, worktree path, base, tip, orphan, waiting
#
# Base and tip are handed over rather than left to the caller to work out. Both
# obvious shortcuts are wrong: the merge-base with main replays a stacked
# entry's parent a second time, and the submitted sha throws away anything
# committed after submitting. `tip` is what to merge; `sha` is what to record.
#
# `orphan` is empty, or "<id> <branch>" of the withdrawn entry this one was
# written on top of -- in which case it must not be merged at all.
#
# `waiting` is empty, or "<state> <id> <branch> <handover tag>" of work this
# entry was started from that is not on main yet. Same conclusion as an orphan
# and a different cause: the work is coming, or nobody has submitted it, but
# either way this entry replays onto a main that has not got it.
#
# Empty output and status 0 mean the queue is empty -- the agent draining it
# wakes to find nothing far more often than it finds work, and that is not an
# error.
cmd_next() {
    local id branch sha base tip orphan waiting
    IFS=$'\t' read -r id branch sha < <(entries "$PENDING_NS") || return 0
    [ -n "${id:-}" ] || return 0
    IFS=$'\t' read -r base tip < <(entry_range "$id" "$branch" "$sha")
    orphan=$(orphaned_by "$base" | tr '\t' ' ')
    waiting=$(waiting_on "$base" | tr '\t' ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$branch" "$sha" \
        "$(worktree_for_branch "$branch")" "$base" "$tip" "$orphan" "$waiting"
}

# A fresh id in the queue's format, for an agent that has to stamp something
# with a time the queue can sort. `/branch-review` writes one into a `Reviewed:`
# trailer, so when a branch was last reviewed reads in the same vocabulary as
# which entry it is, and sorts against it.
#
# Reading the clock is all it does. `claim_id` is the one that takes an id under
# git's ref lock, so this one names nothing and must never be used to name an
# entry: two callers in the same microsecond get the same string, which for a
# timestamp is simply the truth and for an entry id would be a collision.
cmd_id() {
    new_id
}

# Where this script sits inside the repository -- `queue/queue.sh` and the
# `queue/queue.mk` beside it, for an ordinary install. Empty when the script is
# run from outside the repository it is driving (the test harness, or a copy
# kept somewhere else), and then no commit of this repository was ever meant to
# carry it and there is nothing to check.
tooling_paths() {
    local self top dir
    self=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || return 0
    top=$(cd "$(main_checkout)" 2>/dev/null && pwd -P) || return 0
    case "$self/" in "$top/"*) ;; *) return 0 ;; esac
    dir=${self#"$top"/}
    # The script at the repository root is this repository, developing itself.
    [ "$dir" != "$self" ] || return 0
    printf '%s\n' "$dir/queue.sh" "$dir/queue.mk"
}

# Which of those a commit has not got. A path the repository ignores is not
# reported: ignoring the tooling is a decision to carry it outside git, and
# whoever made it does not need telling what it costs.
tooling_missing_from() {
    local commit=$1 top p out=''
    top=$(main_checkout)
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if git cat-file -e "$commit:$p" 2>/dev/null; then continue; fi
        if git check-ignore -q "$top/$p" 2>/dev/null; then continue; fi
        out="$out $p"
    done <<<"$(tooling_paths)"
    printf '%s\n' "${out# }"
}

# Start a piece of work: claim an id, and make a worktree named after it.
#
# The worktree's name used to be invented by whoever was about to do the work,
# which is fine for one person and not fine for several agents working at once:
# two of them asked to fix the same thing independently invent the same name,
# and the second `git worktree add` either fails outright or -- worse -- the
# second agent finds the first's checkout sitting there and works in it.
# Nothing in the repository was the authority on what a piece of work in
# progress is called.
#
# The queue already mints names that cannot collide, because an id is a
# microsecond timestamp taken under git's must-not-exist lock, so that is the
# name the worktree gets. Claiming it here rather than at submission is the
# whole point: the id has to exist before the directory does for the directory
# to be able to carry it.
#
# The BRANCH keeps a descriptive name. It is what `list`, `status`, `show` and
# `diff` are addressed by, and what a reader of the queue recognises, so
# turning it into a timestamp too would make the queue unreadable in exchange
# for uniqueness it already has.
cmd_worktree() {
    local branch='' from='' mc id path start label tag parent state pid pbranch
    local missing

    while [ $# -gt 0 ]; do
        case $1 in
            --from)
                [ $# -ge 2 ] || die "--from needs a handover point, branch or commit"
                from=$2; shift 2 ;;
            --from=*) from=${1#--from=}; shift ;;
            -*) die "unknown option: $1 (worktree takes a branch name and --from <point>)" ;;
            *)  [ -z "$branch" ] ||
                    die "worktree takes one branch name, not '$branch' and '$1'"
                branch=$1; shift ;;
        esac
    done

    [ -n "$branch" ] ||
        die "worktree needs a branch name, e.g. '${CLI}worktree BRANCH=queue-drop-guard'"
    [ "$branch" != "$MAIN" ] ||
        die "$MAIN is the target of the queue, not a branch to work on"
    git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
        die "not a usable branch name: $branch"
    # `! ... || die` rather than `... && die`: under `set -e` a bare
    # `show-ref && die` kills the script when show-ref fails, which is the
    # ordinary case of the branch not existing yet.
    ! git show-ref --verify --quiet "refs/heads/$branch" ||
        die "branch already exists: $branch (one worktree per piece of work)"

    mc=$(main_checkout)
    start=$(git rev-parse "$MAIN")
    label="$MAIN, $(git rev-parse --short "$MAIN")"

    # --from starts the branch somewhere other than main: a handover point on
    # work that is still in progress, another branch's tip, or any commit. The
    # point of naming it HERE rather than letting `submit` work it out is that
    # the declared base is written down before a single commit exists, so the
    # entry submits only this branch's own commits even though its base is a
    # commit in the middle of somebody else's branch -- which is a thing no
    # amount of looking at the finished branch can tell.
    if [ -n "$from" ]; then
        if tag=$(handover_resolve "$from"); then
            from=$tag
            start=$(git rev-parse "refs/tags/$tag^{commit}")
        elif start=$(git rev-parse --verify --quiet "$from^{commit}"); then
            :
        else
            parent=$(find_entry "$from" | first_line)
            [ -n "$parent" ] ||
                die "--from: not a handover point, a branch, a commit or an entry: $from"
            IFS=$'\t' read -r state pid pbranch start <<<"$parent"
            if git show-ref --verify --quiet "refs/heads/$pbranch"; then
                start=$(git rev-parse "refs/heads/$pbranch")
            fi
            from="$pbranch ($pid)"
        fi
        label="$from, $(git rev-parse --short "$start")"
    fi

    # A worktree checks out a COMMIT, not the working tree we are standing in,
    # so tooling that is installed but not committed is simply absent from it:
    # no queue/, no Makefile, and `make queue-submit` in there fails with `No
    # rule to make target`, which the workflow chapter teaches a reader to
    # blame on a branch that predates the install. The install is the thing
    # that predates the commit. Refused here, where the fix is one commit away
    # and no worktree, branch or id has been spent yet.
    missing=$(tooling_missing_from "$start")
    if [ -n "$missing" ]; then
        printf 'queue: %s has no queue tooling in it: %s\n' "$label" "$missing" >&2
        if [ -z "$from" ]; then
            printf '\nThe queue is installed here but not committed, so a worktree off %s\n' "$MAIN" >&2
            printf 'gets a checkout without it. Commit it first, in the main checkout:\n\n' >&2
            printf '    git -C %s add %s\n' "$mc" "$missing" >&2
            printf '    git -C %s commit -m '"'"'build: install the merge queue'"'"'\n' "$mc" >&2
        else
            printf '\nThat point predates the install, so a branch started there cannot\n' >&2
            printf 'reach the queue. Rebase that branch onto %s and take a handover\n' "$MAIN" >&2
            printf 'point on the rebased commit, or start from %s instead.\n' "$MAIN" >&2
        fi
        exit 1
    fi

    id=$(claim_id "$start")
    path="$mc/.worktrees/$id"
    git worktree add -q -b "$branch" "$path" "$start"

    # The declared base, keyed by branch because the branch is what `submit`
    # has in hand and what cannot be two things at once -- `worktree` refuses a
    # branch that already exists. It is consumed at submission and deleted
    # there, so a branch name reused later does not inherit it; a branch
    # started from main clears any left by work that was never submitted.
    if [ -n "$from" ] && ! git merge-base --is-ancestor "$start" "$MAIN" 2>/dev/null; then
        git update-ref "$FROM_NS/$branch" "$start"
    else
        git update-ref -d "$FROM_NS/$branch" 2>/dev/null || true
    fi

    printf 'worktree  %s\n' "$path"
    printf 'branch    %s (from %s)\n' "$branch" "$label"
    printf 'id        %s -- the name of the worktree, and the id submit will use\n' "$id"

    if [ -n "$from" ]; then
        if git merge-base --is-ancestor "$start" "$MAIN" 2>/dev/null; then
            printf "\nthat point is already on $MAIN, so this is an ordinary branch off it\n"
            printf 'and nothing has to land before it can.\n'
        else
            parent=$(handover_parent "$start")
            if [ -n "$parent" ]; then
                IFS=$'\t' read -r state pid pbranch _ <<<"$parent"
                printf 'based on  %s\n' "$(handover_state_line "$state" "$pid" "$pbranch")"
            fi
            printf '\nonly this branch'"'"'s own commits will be submitted, and the entry\n'
            printf 'cannot land before the work below that point does.\n'
            # The base is recorded either way, so the range is right either
            # way. What a handover point adds is the NAME of the branch it was
            # cut from, and that name is the only thing the queue can follow to
            # answer "has the work under this landed yet" -- so without one,
            # submit cannot refuse an entry whose parent never submitted, and
            # drop cannot refuse a withdrawal that would orphan this.
            if [ -z "$parent" ]; then
                printf '\nNo handover point marks that commit, so nothing records whose work\n'
                printf 'it is: the queue cannot tell when it has landed, and withdrawing it\n'
                printf 'will not warn about this branch. Ask that session for one:\n'
                printf '    M="<what is finished here>" %shandover\n' "$CLI"
            fi
        fi
    fi

    printf '\n    cd %s\n' "$path"
}

# Mark a commit on the branch you are working on as a point other work may
# start from -- and say, in writing, what is finished at it.
#
# With no arguments it lists the points that exist and where the work below
# each one stands; with a name it shows one in full. `-m` is what creates one,
# so the message is not an argument to the creation -- it is the request for
# it.
#
# The message is not optional, for the same reason an entry's merge message is
# not: a handover point with nothing to say is a sha, and a sha is what this
# exists to replace. What the next session needs to know is which part of the
# work is finished at this commit and which part is not, and the only one who
# knows that is whoever stopped here.
cmd_handover() {
    local msg='' at='' want='' creating=0
    local branch tag seq commit short state id pbranch base below rest
    local children declared

    while [ $# -gt 0 ]; do
        case $1 in
            -m|--message)
                [ $# -ge 2 ] || die "-m needs a message"
                msg=$2; creating=1; shift 2 ;;
            --at)
                [ $# -ge 2 ] || die "--at needs a commit"
                at=$2; shift 2 ;;
            --at=*) at=${1#--at=}; shift ;;
            -*) die "unknown option: $1 (handover takes a name, or -m <text> [--at <commit>])" ;;
            *)  [ -z "$want" ] ||
                    die "handover shows one point, not '$want' and '$1'"
                want=$1; shift ;;
        esac
    done

    [ "$creating" = 0 ] || [ -z "$want" ] ||
        die "-m creates a point on the branch you are on; --at names the commit, not '$want'"
    if [ -n "$at" ] && [ "$creating" = 0 ]; then
        die "--at names the commit to mark, so it needs -m <text> as well"
    fi

    # ---- create ----
    if [ "$creating" = 1 ]; then
        [ -n "$(printf '%s' "$msg" | tr -d '[:space:]')" ] || die "$(cat <<EOF
a handover point needs a message saying what is finished at it.

Without one it is a sha with a name, and the next session is back to reading
the queue to work out what it can rely on:

    M="the request parser is done and tested.
    The response path is NOT -- handler.go is a stub." ${CLI}handover
EOF
)"
        branch=$(git symbolic-ref --quiet --short HEAD) ||
            die "HEAD is detached; a handover point is a point on a branch"
        [ "$branch" != "$MAIN" ] ||
            die "$MAIN needs no handover point: a branch off $MAIN starts from $MAIN"

        commit=$(git rev-parse --verify "${at:-HEAD}^{commit}") ||
            die "not a commit: ${at:-HEAD}"
        # The tag's NAME says which branch the point is on, so a commit that is
        # not on that branch would make the name a lie -- and `worktree --from`
        # reads the branch back out of the name to find out whose work it is
        # waiting for.
        git merge-base --is-ancestor "$commit" "$branch" 2>/dev/null ||
            die "$(git rev-parse --short "$commit") is not on $branch"
        ! git merge-base --is-ancestor "$commit" "$MAIN" 2>/dev/null || die "$(printf '%s\n\n    %s\n' \
            "$(git rev-parse --short "$commit") is already on $MAIN, so nothing has to be handed over: a branch started there starts from $MAIN." \
            "${CLI}worktree BRANCH=<branch>")"

        seq=$(handover_next_seq "$branch")
        tag="$HANDOVER_NS/$branch/$seq"
        short=$(git rev-parse --short "$commit")
        # Annotated (-a via -m), so the message is part of the tag object and
        # travels with it. A lightweight tag would pin the commit just as well
        # and have nowhere to put the half of this that matters.
        printf '%s\n' "$msg" | git tag -a -F - "$tag" "$commit"

        IFS=$'\t' read -r state id pbranch < <(handover_entry "$tag")
        printf 'handover  %s  at %s\n' "$tag" "$short"
        printf 'branch    %s\n' "$(handover_state_line "$state" "$id" "$pbranch")"
        printf '\n  the branch point for a handover document -- it survives this branch\n'
        printf '  landing as a squash and being deleted:\n\n'
        printf '      %sworktree BRANCH=<branch> FROM=%s\n' "$CLI" "$tag"
        return 0
    fi

    # ---- show one ----
    if [ -n "$want" ]; then
        tag=$(handover_resolve "$want") || die "no handover point named '$want' (${CLI}handovers lists them)"
        commit=$(git rev-parse "refs/tags/$tag^{commit}")
        IFS=$'\t' read -r state id pbranch < <(handover_entry "$tag")

        printf 'handover   %s\n' "$tag"
        printf 'commit     %s %s\n' "$(git rev-parse --short "$commit")" \
            "$(git log -1 --format=%s "$commit")"
        printf 'branch     %s\n' "$(handover_state_line "$state" "$id" "$pbranch")"

        if [ "$state" = dropped ]; then
            printf 'ORPHANED   the work below this point was withdrawn, so it will never\n'
            printf "           reach $MAIN and anything started here is orphaned. Rebase\n"
            printf "           that work onto $MAIN, or resubmit it, before relying on this.\n"
        fi

        if git show-ref --verify --quiet "refs/heads/$pbranch" &&
           ! git merge-base --is-ancestor "$commit" "refs/heads/$pbranch" 2>/dev/null; then
            printf 'REWRITTEN  %s no longer contains this commit, so its history was\n' "$pbranch"
            printf '           rebased after the point was taken. Work started here is still\n'
            printf '           sound -- its own commits are unaffected -- but what lands\n'
            printf '           below it will not be these commits.\n'
        fi

        printf '\nwhat is finished here, in the author'"'"'s words:\n'
        git tag -l --format='%(contents)' "$tag" | sed 's/^./  &/'

        # The work BELOW the point: the parent's own commits up to it. This is
        # the mechanical half of "what is complete", and it cannot change --
        # which is the whole purpose of the tag.
        # `-` is `handover_entry`'s no-id placeholder, so this is "the branch
        # has an entry": then the base is the recorded one, and otherwise the
        # merge-base with main, which is what that branch was started from.
        if [ "$id" != - ]; then
            base=$(entry_base "$id" "$pbranch" "$commit")
        else
            base=$(git merge-base "$MAIN" "$commit" 2>/dev/null || true)
        fi
        if [ -n "$base" ]; then
            below=$(git rev-list --count "$base".."$commit")
            printf '\ncomplete below this point (%s commit%s):\n' \
                "$below" "$( [ "$below" = 1 ] || echo s )"
            git log --reverse --format='  %h %s' "$base".."$commit"
        fi

        # And what the parent did AFTER it, which is what a reader starting
        # here does NOT have and will receive when that entry lands.
        if git show-ref --verify --quiet "refs/heads/$pbranch"; then
            rest=$(git rev-list --count "$commit..refs/heads/$pbranch" 2>/dev/null || echo 0)
            if [ "$rest" != 0 ]; then
                printf '\nadded to %s after this point (%s commit%s), which arrive when it lands:\n' \
                    "$pbranch" "$rest" "$( [ "$rest" = 1 ] || echo s )"
                git log --reverse --format='  %h %s' "$commit..refs/heads/$pbranch"
            fi
        elif [ "$state" = merged ]; then
            printf "\n%s has landed, so everything above this point is on $MAIN too.\n" "$pbranch"
        fi

        children=$(pending_children_of "$commit")
        declared=$(git for-each-ref --format='%(refname) %(objectname)' "$FROM_NS" |
                   awk -v c="$commit" -v n="$FROM_NS/" '$2 == c { print substr($1, length(n) + 1) }')
        if [ -n "$children" ] || [ -n "$declared" ]; then
            printf '\nstarted from it:\n'
            [ -z "$children" ] ||
                printf '%s' "$children" | awk -F'\t' '{printf "  %s  %s  (queued)\n", $1, $2}'
            [ -z "$declared" ] ||
                printf '%s\n' "$declared" | sed 's/^/  /; s/$/  (not submitted)/'
        fi

        printf '\nstart work from it:\n      %sworktree BRANCH=<branch> FROM=%s\n' "$CLI" "$tag"
        return 0
    fi

    # ---- list ----
    if [ -z "$(git tag --list "$HANDOVER_NS/*")" ]; then
        printf 'no handover points.\n\n'
        printf 'One marks a commit on the branch you are working on as a point other\n'
        printf 'work may start from, and says what is finished at it:\n\n'
        printf '    M="<what is done here, and what is not>" %shandover\n' "$CLI"
        return 0
    fi
    printf '%-34s %-9s %-44s %s\n' POINT COMMIT 'WORK BELOW IT' 'WHAT IS FINISHED THERE'
    while read -r tag; do
        [ -n "$tag" ] || continue
        commit=$(git rev-parse "refs/tags/$tag^{commit}")
        IFS=$'\t' read -r state id pbranch < <(handover_entry "$tag")
        printf '%-34s %-9s %-44s %s\n' "$tag" "$(git rev-parse --short "$commit")" \
            "$(handover_state_line "$state" "$id" "$pbranch")" \
            "$(git tag -l --format='%(contents:subject)' "$tag")"
    done < <(git tag --list "$HANDOVER_NS/*" | sort)
    printf '\n    %-38s one in full: what is finished there\n' "${CLI}handover POINT=<point>"
    printf '    %-38s take one here, on the branch you are on\n' "M=\"<text>\" ${CLI}handover"
}

# The id a submission takes: the one its worktree is already named after, if it
# has one, and otherwise a freshly claimed one.
#
# Reading the id back off the directory name is what makes the worktree's name
# and the entry's id the same string, rather than merely both unique. The claim
# ref has to be there too -- a directory someone named to look like an id never
# went through `claim_id`, so nothing guarantees it is unique and it is not
# treated as an id.
#
# A worktree made by hand keeps the old behaviour: no id in its name, so one is
# claimed here as before. The point is to make the good path available, not to
# refuse work that did not take it.
submission_id() {
    local branch=$1 wt=${2:-} candidate state
    if [ -n "$wt" ]; then
        candidate=$(basename "$wt")
        if is_queue_id "$candidate" &&
           git show-ref --verify --quiet "$ID_NS/$candidate"; then
            state=$(id_state "$candidate")
            if [ -z "$state" ]; then
                printf '%s\n' "$candidate"
                return
            fi
            # The id is spent -- most often on an entry that was withdrawn and
            # is now being resubmitted from the same worktree. A fresh id keeps
            # one id to one entry, at the cost of this worktree's name no longer
            # matching it, which is said out loud rather than left to be noticed
            # later by someone wondering which is which.
            printf 'queue: the worktree is named %s, but that id is already a %s entry,\n' \
                "$candidate" "$state" >&2
            printf 'queue: so this submission takes a new id and the two no longer match\n' >&2
        fi
    fi
    claim_id "$(git rev-parse "$branch")"
}

# The branch point declared before the work, if there is one and it is still
# true. `worktree --from` writes it; this is the read.
#
# Discarded when it is no longer an ancestor of the tip, which means the branch
# was rebased after it was declared -- the declaration described a history that
# no longer exists, and the range from it would mean nothing.
declared_base() {
    local branch=$1 tip=$2 base
    git show-ref --verify --quiet "$FROM_NS/$branch" || return 0
    base=$(git rev-parse "$FROM_NS/$branch")
    git merge-base --is-ancestor "$base" "$tip" 2>/dev/null || return 0
    printf '%s\n' "$base"
}

cmd_submit() {
    local branch='' msg='' id base ahead wt parent pid pbranch psha
    local tip declared blocker state btag orphan

    # `-m`, git's spelling of the same idea. An option rather than a second
    # positional because the message is usually several lines, and because a
    # branch and a message are not distinguishable by position when either one
    # may be left out.
    while [ $# -gt 0 ]; do
        case $1 in
            -m|--message)
                [ $# -ge 2 ] || die "-m needs a message"
                msg=$2; shift 2 ;;
            -*) die "unknown option: $1 (submit takes a branch and -m <message>)" ;;
            *)  [ -z "$branch" ] ||
                    die "submit takes one branch, not '$branch' and '$1'"
                branch=$1; shift ;;
        esac
    done

    if [ -z "$branch" ]; then
        branch=$(git symbolic-ref --quiet --short HEAD) ||
            die "HEAD is detached; name the branch to submit"
    fi

    git show-ref --verify --quiet "refs/heads/$branch" ||
        die "no such branch: $branch"
    [ "$branch" != "$MAIN" ] ||
        die "$MAIN is the target of the queue, not an entry in it"
    [ -z "$(pending_for_branch "$branch")" ] ||
        die "$branch is already queued as $(pending_for_branch "$branch" | cut -f1)"

    # Only the worktree that HAS the branch checked out can be dirty in a way
    # that matters: uncommitted work would be left behind by a merge of the
    # branch tip, silently, and the author is the only one who can tell whether
    # that was deliberate.
    wt=$(worktree_for_branch "$branch")
    if [ -n "$wt" ] && [ -n "$(git -C "$wt" status --porcelain)" ]; then
        die "$wt has uncommitted changes; commit or stash them first"
    fi

    # Three answers to "what was this written against", in order of how much
    # they know. A pending entry whose submitted tip is already in this branch
    # is the most precise, because it is the latest point someone else's work
    # reached. A base DECLARED before the work is next, and is the only one
    # that can name a commit in the middle of another branch -- nothing about
    # the finished branch distinguishes that from a commit of its own. The
    # merge-base with main is the fallback, and the only answer for a branch
    # that was started the ordinary way.
    #
    # The declared base yields to the stacked tip when the tip is further
    # along: the branch was started from a parent's tip and that parent has
    # submitted since, so the declaration is now behind what it meant, and
    # using it would submit the parent's last few commits a second time.
    tip=$(git rev-parse "$branch")
    declared=$(declared_base "$branch" "$tip")
    parent=$(stacked_on "$tip")
    if [ -n "$parent" ]; then
        IFS=$'\t' read -r pid pbranch psha <<<"$parent"
        if [ -z "$declared" ] ||
           git merge-base --is-ancestor "$declared" "$psha" 2>/dev/null; then
            base=$psha
        else
            base=$declared
            parent=''
        fi
    elif [ -n "$declared" ]; then
        base=$declared
    else
        base=$(git merge-base "$MAIN" "$branch")
    fi
    ahead=$(git rev-list --count "$base".."$branch")
    [ "$ahead" -gt 0 ] || die "$branch has nothing $MAIN does not already have"

    # The queue orders what is in it, so everything an entry depends on has to
    # be in it too. A handover base says exactly what this entry depends on --
    # the branch the tag was cut from -- and there are two answers that cannot
    # be ordered: work that was withdrawn, and work nobody has submitted.
    #
    # Refusing here rather than at the drain keeps the queue always drainable:
    # an entry waiting for a session that may never submit would stop the drain
    # and everything behind it, and the drain is not the place to find that out.
    orphan=$(orphaned_by "$base")
    if [ -n "$orphan" ]; then
        die "$(printf '%s\n\n%s\n' \
            "the work $branch is based on was withdrawn: entry $(printf '%s' "$orphan" | tr '\t' ' ')" \
            "Submitting it would put commits on $MAIN that were written against work $MAIN never receives -- usually without one conflict to warn anyone. Rebase onto $MAIN first, then submit.")"
    fi
    blocker=$(waiting_on "$base")
    if [ -n "$blocker" ]; then
        IFS=$'\t' read -r state pid pbranch btag <<<"$blocker"
        if [ "$state" = unsubmitted ]; then
            die "$(printf '%s\n\n%s\n\n    %s\n' \
                "$pbranch has not been submitted yet." \
                "$branch is based on $btag, so it cannot land until that work does -- and the queue only orders what is in it. Ask that session to submit; submitting is not a freeze, and it can keep committing afterwards." \
                "${CLI}show ENTRY=$pbranch   # once it is in, submit this again")"
        fi
    fi

    # The changelog used to be the entry's description of itself, and a branch
    # that did not touch CHANGELOG.md was the reliable sign of a submission
    # made one step early. The message is that description now -- and unlike a
    # changelog entry it cannot be skipped for a change too small to be
    # notable: the drain squashes the entry into one commit on main and this is
    # that commit's message, so an entry without one has nothing to land under.
    [ -n "$(printf '%s' "$msg" | tr -d '[:space:]')" ] || die "$(cat <<EOF
$branch has no merge message.

The drain squashes this entry into a single commit on $MAIN and takes that
commit's message from here, so every submission needs one: a short subject, a
blank line, then a body saying what the change does.

    M="queue: squash each merged entry into one commit

    Changed the merge queue to squash merge, so $MAIN keeps one commit per
    entry describing the change instead of the steps towards it." ${CLI}submit
EOF
)"
    warn_msg_shape "$msg"

    # Base and message first, pending ref last. The pending ref is what makes
    # the entry visible to a drain, and a drain that can see an entry but not
    # its message cannot land it.
    id=$(submission_id "$branch" "$wt")

    # Merge order is id order, and this entry has to come after the one it is
    # based on. It almost always does for nothing: the handover tag existed
    # before this worktree, so the id claimed for this worktree is later than
    # the one claimed for the branch the tag was cut from.
    #
    # Almost. A worktree made by hand carries no id, so its branch claims one
    # at SUBMISSION -- which can be after this one's, putting the work this
    # entry needs behind the entry that needs it. A fresh id puts them back in
    # the right order, at the cost of this worktree's name no longer matching
    # its entry, which is said out loud rather than left to be discovered.
    if [ -n "$blocker" ] && [ "$state" = pending ] && [ ! "$id" \> "$pid" ]; then
        printf 'queue: %s is pending as %s, which sorts after this worktree'"'"'s own id,\n' \
            "$pbranch" "$pid" >&2
        printf 'queue: so this submission takes a new id to stay behind it in the order\n' >&2
        id=$(claim_id "$tip")
    fi

    git update-ref "$BASE_NS/$id/$branch" "$base"
    # Consumed: the base is recorded against the entry now, and a branch name
    # reused by later work must not inherit this one's branch point.
    git update-ref -d "$FROM_NS/$branch" 2>/dev/null || true
    store_msg "$id" "$branch" "$msg"
    git update-ref --create-reflog -m submitted "$PENDING_NS/$id/$branch" "$branch"
    printf 'queued %s as %s (%s, %s commit%s)\n' \
        "$branch" "$id" "$(git rev-parse --short "$branch")" \
        "$ahead" "$( [ "$ahead" = 1 ] || echo s )"
    printf 'message: %s\n' "$(printf '%s\n' "$msg" | first_line)"
    printf '%s ahead of it in the queue\n' \
        "$(( $(entries "$PENDING_NS" | grep -c .) - 1 ))"
    if [ -n "$parent" ]; then
        printf 'stacked on %s (%s): only this branch'"'"'s own commits were submitted,\n' \
            "$pid" "$pbranch"
        printf 'and it cannot land before that entry does.\n'
    elif [ -n "$declared" ] && [ "$base" = "$declared" ]; then
        btag=$(handover_at "$base")
        printf 'based on %s: only this branch'"'"'s own commits were submitted,\n' \
            "${btag:-$(git rev-parse --short "$base")}"
        printf 'and it cannot land before the work below that point does.\n'
        blocker=$(handover_parent "$base")
        if [ -n "$blocker" ]; then
            IFS=$'\t' read -r state pid pbranch btag <<<"$blocker"
            printf '    %s\n' "$(handover_state_line "$state" "$pid" "$pbranch")"
        fi
    fi
    # Submitting is not a freeze: the drain merges whatever the branch points
    # at when it gets there. Said out loud because the opposite is a reasonable
    # thing to assume, and the difference decides whether a later fix lands.
    printf 'the drain will merge this branch as it stands then, not as it stands now\n'
}

# Print an entry's merge message, or replace it.
#
# Printing is how the drain reads the message it is about to commit. Replacing
# it is for when the work continued after submission -- ordinary, because
# submitting is not a freeze -- and the message no longer describes what the
# entry does. The same flag as `submit`, because it is the same text.
cmd_message() {
    local want='' msg='' setting=0 entry state id branch sha out

    while [ $# -gt 0 ]; do
        case $1 in
            -m|--message)
                [ $# -ge 2 ] || die "-m needs a message"
                msg=$2; setting=1; shift 2 ;;
            -*) die "unknown option: $1 (message takes an entry and -m <message>)" ;;
            *)  [ -z "$want" ] ||
                    die "message takes one entry, not '$want' and '$1'"
                want=$1; shift ;;
        esac
    done

    [ -n "$want" ] || die "message needs an id or branch, e.g. '${CLI}message ENTRY=api-fix'"
    entry=$(resolve_entry "$want")
    IFS=$'\t' read -r state id branch sha <<<"$entry"

    if [ "$setting" = 1 ]; then
        # A merged entry's message is a commit message on main now. Rewriting
        # the ref would say one thing while main says another, and main is the
        # one anybody reads.
        [ "$state" = pending ] ||
            die "$id ($branch) is $state; its message is on $MAIN now, not in the queue"
        [ -n "$(printf '%s' "$msg" | tr -d '[:space:]')" ] ||
            die "an empty message would leave $id with nothing to land under"
        warn_msg_shape "$msg"
        store_msg "$id" "$branch" "$msg"
        printf 'message set for %s %s\n' "$id" "$branch"
        return
    fi

    out=$(load_msg "$id" "$branch")
    [ -n "$out" ] || die "$(printf '%s\n\n    %s\n' \
        "$id ($branch) has no merge message recorded" \
        "M=\"<subject>\" ${CLI}message ENTRY=$branch")"
    printf '%s\n' "$out"
}

# Move an entry from pending to drained. The sha recorded is the one that was
# SUBMITTED, not whatever it became on main: the pair (submitted, merged) is
# what makes a rebase auditable afterwards.
# The message an entry's commit on main will actually carry: the author's, plus
# the provenance trailer the queue appends to it.
#
# This exists for the draining agent's hand path. When a conflict stops the
# drain, that agent repeats the drain's own steps with a resolution in the
# middle, and the commit at the end of them has to be the commit the drain
# would have made -- so the trailer cannot be a line typed out in a skill.
# Written there it drifts from the script, and it drifts on exactly the entries
# whose provenance is worth the most: the ones somebody had to make a decision
# about.
cmd_landing_message() {
    local entry id branch sha
    [ $# -ge 1 ] ||
        die "landing-message needs an id or branch, e.g. '${CLI}landing-message ENTRY=api-fix'"
    entry=$(pending_for_id "$1") || true
    [ -n "$entry" ] || die "no pending entry matching '$1'"
    IFS=$'\t' read -r id branch sha <<<"$entry"
    [ -n "$(load_msg "$id" "$branch")" ] ||
        die "$id ($branch) has no merge message, so its commit on $MAIN would have nothing to say"
    landing_msg "$id" "$branch" "$sha"
}

cmd_complete() {
    local entry id branch sha
    [ $# -ge 1 ] || die "complete needs an id or branch, e.g. '${CLI}complete ENTRY=api-fix'"
    entry=$(pending_for_id "$1") || true
    [ -n "$entry" ] || die "no pending entry matching '$1'"
    IFS=$'\t' read -r id branch sha <<<"$entry"
    git update-ref --create-reflog -m merged "$DONE_NS/$id/$branch" "$sha"
    git update-ref -d "$PENDING_NS/$id/$branch"
    printf 'completed %s %s\n' "$id" "$branch"
}

# Withdraw an entry without merging it. The branch and its worktree are left
# alone -- only the queue forgets about them, and it remembers that it did.
cmd_drop() {
    local entry id branch sha children

    [ $# -ge 1 ] || die "drop needs an id or branch, e.g. '${CLI}drop ENTRY=api-fix'"

    # A drain holds the queue while it works. Withdrawing an entry underneath
    # it produces the worst outcome available: the drain fast-forwards main
    # anyway and then cannot mark the entry merged, so the work is on main and
    # the log says it was withdrawn.
    if drain_in_progress; then
        die "$(cat <<EOF
a drain is in progress, so the queue is not accepting withdrawals.

Wait for it to finish. If no drain is actually running, it died and left its
worktree behind -- check, then remove it:

    git worktree remove --force $(drain_lock)
EOF
)"
    fi

    entry=$(pending_for_id "$1") || true
    [ -n "$entry" ] || die "no pending entry matching '$1'"
    IFS=$'\t' read -r id branch sha <<<"$entry"

    # Entries written on top of this one lose the ground under them. Nothing
    # downstream can tell: their replay may well be conflict-free and simply
    # wrong, because the code they were written against never arrives.
    children=$(pending_children_of "$sha" "$branch")
    if [ -n "$children" ] && [ "${FORCE_DROP:-}" != 1 ]; then
        die "$(printf '%s\n\n%s\n\n%s\n\n    %s\n' \
            "$id ($branch) has work stacked on top of it:" \
            "$(printf '%s' "$children" | awk -F'\t' '{printf "    %s  %s\n", $1, $2}')" \
            "Dropping it orphans those entries: they would replay onto a $MAIN that never receives what they were written against, and a clean replay of orphaned work is still broken work. Drop them first, or rebase them onto $MAIN -- or, if you know what you are doing:" \
            "FORCE_DROP=1 ${CLI}drop ENTRY=$1")"
    fi

    git update-ref --create-reflog -m dropped "$DROPPED_NS/$id/$branch" "$sha"
    git update-ref -d "$PENDING_NS/$id/$branch"
    printf 'dropped %s %s (branch and worktree left alone)\n' "$id" "$branch"
    if [ -n "$children" ]; then
        printf "\nORPHANED, and now unmergeable until rebased onto $MAIN:\n"
        printf '%s' "$children" | awk -F'\t' '{printf "    %s  %s\n", $1, $2}'
    fi
}

# ---------------------------------------------------------------------------
# Draining
# ---------------------------------------------------------------------------

# Land the queue on main, in submission order, one squashed commit per entry --
# and stop at the first entry that needs a decision instead of making it.
#
# This is the whole drain except conflict resolution: take the lock, replay the
# entry's own commits onto main, squash them under the message its author
# submitted, fast-forward main, mark the entry drained, remove the branch and
# its worktree, then take the next entry. What it will not do is resolve a
# conflict. A conflict is two intentions colliding, and choosing between them
# is a judgement about someone else's code that has to be made by a reader and
# written down as a git note -- `/merge-queue` is that reader, and it picks up
# exactly where this stops.
#
# The conflict test IS the replay, deliberately. A separate dry run -- a probe
# rebase, `merge-tree`, `apply --check` -- is a second opinion that can
# disagree with the operation it predicts, and then the drain either refuses a
# merge that would have worked or starts one that does not. The replay happens
# in the scratch worktree, where failing costs nothing: it touches neither main
# nor the entry, and it is aborted and reported. Main is written only by the
# fast-forward, which cannot be reached until the replay has already come back
# clean -- so "merge only if there are no conflicts" is not a check in front of
# the merge, it is the order the steps happen in.
#
# Stops at the first blockage and leaves that entry pending: an orphan, an
# entry with no message, a conflict, a replay that comes to nothing, or a main
# checkout that will not fast-forward. Entries already landed stay landed, and
# the report names what stopped it. Exits non-zero if anything was left
# pending that was not simply behind a blockage.
# test_entry <worktree> <id>: runs QUEUE_TEST in <worktree>, keeping what it
# says in a log under the common git dir, since the worktree is the drain's
# scratch one and goes when the drain does. Prints the log's path, and fails if
# the test does.
test_entry() {
    local dir=$1 id=$2 log
    log="$(git rev-parse --path-format=absolute --git-common-dir)/merge-queue-logs/$id.log"
    mkdir -p "$(dirname "$log")"
    printf '%s\n' "$log"
    ( cd "$dir" && sh -c "$TEST" ) >"$log" 2>&1
}

cmd_drain() {
    local mc lock top head landed=0 pending rc=0
    local id branch sha wt base tip orphan waiting msg squashed conflicted err
    local next_line f log

    mc=$(main_checkout)

    # The drain writes main and removes the branches and worktrees it lands, so
    # it runs in the main checkout. From inside a worktree it could be asked to
    # delete the ground it is standing on.
    top=$(git rev-parse --show-toplevel)
    [ "$top" = "$mc" ] || die "$(printf 'the drain runs in the main checkout, not in %s:\n\n    cd %s && %sdrain\n' "$top" "$mc" "$CLI")"

    head=$(git -C "$mc" symbolic-ref --quiet --short HEAD || true)
    [ "$head" = "$MAIN" ] ||
        die "the main checkout is on ${head:-a detached HEAD}, not $MAIN, and the drain fast-forwards $MAIN"

    if [ -z "$(entries "$PENDING_NS")" ]; then
        echo "queue is empty -- nothing to drain"
        return 0
    fi

    if drain_in_progress; then
        die "$(cat <<EOF
a drain already holds the queue: $(drain_lock)

Only one drain runs at a time. If none actually is, one died and left its
worktree behind -- inspect it before removing it, since it may be sitting in a
half-finished rebase whose resolutions are worth keeping:

    git worktree remove --force $(drain_lock)
EOF
)"
    fi

    # The lock is the worktree's existence, so it is taken before the queue is
    # read: read first and lock second, and an entry can be withdrawn or a
    # second drain started in the gap between the two.
    lock=$(drain_lock)
    git worktree add -q --detach "$lock" "$MAIN" ||
        die "could not take the drain lock ($lock)"
    # Removed on every exit path, including an interrupt part-way through a
    # rebase. Double quotes, so $lock is baked in now -- see the same note on
    # `check`, where deferring it left behind the worktree the trap exists to
    # remove.
    trap "git -C '$lock' rebase --abort >/dev/null 2>&1 || true
          git worktree remove --force '$lock' >/dev/null 2>&1 || true" EXIT INT TERM

    printf "draining onto $MAIN (%s)\n\n" "$(git -C "$mc" rev-parse --short "$MAIN")"

    while :; do
        # `tr` into lines and `mapfile`, not `IFS=$'\t' read`. Three of these
        # eight columns are empty in ordinary cases -- no worktree, no orphan,
        # nothing waited on -- and bash's `read` collapses adjacent tabs into
        # one delimiter, so an empty column shifts every column after it. That
        # put `base` in `wt` and emptied `tip`, and the drain then reported a
        # conflict in a rebase it had mangled the arguments of.
        id=''; branch=''; sha=''; wt=''; base=''; tip=''; orphan=''; waiting=''
        next_line=$(cmd_next) || true
        [ -n "$next_line" ] || break
        mapfile -t f < <(printf '%s' "$next_line" | tr '\t' '\n')
        id=${f[0]:-}; branch=${f[1]:-}; sha=${f[2]:-}; wt=${f[3]:-}
        base=${f[4]:-}; tip=${f[5]:-}; orphan=${f[6]:-}; waiting=${f[7]:-}
        [ -n "$id" ] || break

        # An orphan is not replayed. It would usually replay perfectly
        # cleanly, and that is the misleading part: what it was written against
        # was withdrawn and never arrives.
        if [ -n "$orphan" ]; then
            printf '  %-23s %-26s BLOCKED\n' "$id" "$branch"
            printf '           written on top of withdrawn entry %s\n' "$orphan"
            printf "           rebase it onto $MAIN before it can land\n"
            rc=1; break
        fi

        # Work this entry was started from that main has not got. Reaching
        # this in submission order should be impossible -- the entry below was
        # submitted first and has already landed by here -- so it means the
        # order was inverted, and replaying would land commits written against
        # a commit main has never seen.
        if [ -n "$waiting" ]; then
            printf '  %-23s %-26s BLOCKED\n' "$id" "$branch"
            printf '           %s\n' "$(waiting_report "$(waiting_on "$base")")"
            printf "           that work is not on $MAIN, so this would replay onto a commit\n"
            printf "           $MAIN has never seen -- land it first, or rebase onto $MAIN\n"
            rc=1; break
        fi

        msg=$(load_msg "$id" "$branch")
        if [ -z "$msg" ]; then
            printf '  %-23s %-26s BLOCKED\n' "$id" "$branch"
            printf '           no merge message, so the squash commit has nothing to say\n'
            printf '           its author gives it one: M="..." %smessage ENTRY=%s\n' "$CLI" "$id"
            rc=1; break
        fi

        if [ -z "$base" ]; then
            printf '  %-23s %-26s BLOCKED\n' "$id" "$branch"
            printf '           cannot tell what it was written against\n'
            rc=1; break
        fi

        # Each entry starts from main as it now stands, which after a landing
        # is the commit this worktree is already on. Stated rather than
        # assumed, so the replay below starts from the same place every time.
        git -C "$lock" reset -q --hard "$MAIN"

        if ! git -C "$lock" rebase --onto HEAD "$base" "$tip" >/dev/null 2>&1; then
            conflicted=$(git -C "$lock" diff --name-only --diff-filter=U)
            git -C "$lock" rebase --abort >/dev/null 2>&1 || true
            printf '  %-23s %-26s CONFLICT\n' "$id" "$branch"
            printf '%s\n' "$conflicted" | sed 's/^/           /'
            printf "           left pending, and $MAIN untouched: resolving it is /merge-queue work\n"
            rc=1; break
        fi

        # `reset --soft` puts HEAD back on main with the replayed tree still in
        # the index, so the commit that follows is that whole tree in one step.
        # --author keeps the work attributed to whoever wrote it; the committer
        # is whoever drained, which is the record of how it got here.
        git -C "$lock" reset -q --soft "$MAIN"
        if ! landing_msg "$id" "$branch" "$sha" |
             git -C "$lock" commit -q -F - \
                 --author="$(git log -1 --format='%an <%ae>' "$tip")" >/dev/null 2>&1; then
            git -C "$lock" reset -q --hard "$MAIN"
            printf '  %-23s %-26s BLOCKED\n' "$id" "$branch"
            printf "           replays to nothing -- $MAIN already has this tree\n"
            rc=1; break
        fi
        squashed=$(git -C "$lock" rev-parse HEAD)

        # The tree as it will land, tested before main moves to it. A failure
        # is the entry's to fix, as a conflict is: it stays pending, and what
        # is behind it waits, since that was written on top of it.
        if [ -n "$TEST" ] && ! log=$(test_entry "$lock" "$id"); then
            git -C "$lock" reset -q --hard "$MAIN"
            printf '  %-23s %-26s TESTS FAILED\n' "$id" "$branch"
            tail -n 15 "$log" | sed 's/^/           /'
            printf '           %s, in full: %s\n' "$TEST" "$log"
            printf "           left pending, and $MAIN untouched\n"
            rc=1; break
        fi

        # --ff-only is the safety rail and also the only check on the state of
        # the main checkout, which is the right one to have: it refuses exactly
        # when the merge would overwrite a modified tracked file or an
        # untracked file in its way, and it names the file. An unrelated dirty
        # file cannot affect the merge, and pre-screening for one would stop
        # the queue for nothing.
        if ! err=$(git -C "$mc" merge --ff-only -q "$squashed" 2>&1); then
            printf '  %-23s %-26s BLOCKED\n' "$id" "$branch"
            printf '%s\n' "$err" | sed 's/^/           /'
            rc=1; break
        fi

        cmd_complete "$id" >/dev/null
        landed=$(( landed + 1 ))
        printf '  %-23s %-26s squashed to %s%s\n' \
            "$id" "$branch" "$(git rev-parse --short "$squashed")" "${TEST:+, tested}"

        # The author was told to leave the branch and the worktree alone, so clearing
        # them up is the drain's job. The tip comparison is the check
        # `-D` cannot do for us: the rebase rewrote these commits and the
        # squash replaced them, so `-d` refuses even when everything landed --
        # while a branch that moved AGAIN during the drain has commits that did
        # not land, and deleting it would take them with it.
        if [ -n "$wt" ] && [ "$wt" != "$mc" ]; then
            git worktree remove --force "$wt" >/dev/null 2>&1 ||
                printf '           worktree %s could not be removed\n' "$wt"
        fi
        if [ "$(git rev-parse --verify --quiet "refs/heads/$branch" || true)" = "$tip" ]; then
            git branch -q -D "$branch" >/dev/null 2>&1 || true
        elif git show-ref --verify --quiet "refs/heads/$branch"; then
            printf '           branch %s kept: it moved again during the drain\n' "$branch"
        fi
    done

    pending=$(entries "$PENDING_NS" | grep -c . || true)
    printf "\nlanded %s, $MAIN now at %s, %s still pending\n" \
        "$landed" "$(git -C "$mc" rev-parse --short "$MAIN")" "$pending"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Inspection
#
# Everything from here to the next section answers a question about the queue
# without changing it. The one exception is `check`, which needs a real
# worktree to replay commits in; it builds a scratch one, removes it on every
# exit path, and never touches main, the entries, or the submitted branches. It
# is `drain` with the landing left out, which is why the two replay the same
# range with the same command.
# ---------------------------------------------------------------------------

# The repository's main checkout -- the queue's merge target, and the only
# place a drain runs. The common git dir is shared by every worktree, so its
# parent is the main checkout no matter which worktree we are called from.
main_checkout() {
    dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
}

# When an entry entered its current state, read from the ref's reflog.
# Submissions made before submit started passing --create-reflog have none, so
# an unknown age is a normal answer and not an error.
ref_date() {
    local ref=$1 fmt=${2:-relative} out
    out=$(git reflog show --date="$fmt" "$ref" 2>/dev/null | tail -1) || true
    [ -n "$out" ] || { echo unknown; return; }
    printf '%s\n' "$out" | sed 's/.*@{\(.*\)}.*/\1/'
}

# An entry in any namespace, as TAB-separated state, id, branch, sha.
# Accepts a full id, a unique id prefix, or a branch name -- at a terminal
# prompt the branch is what you remember. Pending is searched first, so a
# branch submitted, withdrawn and resubmitted resolves to the live entry.
find_entry() {
    local want=$1 ns state id branch sha
    for ns in "$PENDING_NS" "$DONE_NS" "$DROPPED_NS"; do
        case "$ns" in
            "$PENDING_NS") state=pending ;;
            "$DONE_NS")    state=merged ;;
            *)             state=dropped ;;
        esac
        entries "$ns" | while IFS=$'\t' read -r id branch sha; do
            if [ "$id" = "$want" ] || [ "$branch" = "$want" ] ||
               { [ -n "$want" ] && [ "${id#"$want"}" != "$id" ]; }; then
                printf '%s\t%s\t%s\t%s\n' "$state" "$id" "$branch" "$sha"
            fi
        done
    done
}

# One entry, or an error naming the alternatives.
#
# Exact id and exact branch win outright; otherwise a prefix must match exactly
# one entry. An ambiguous prefix is an error rather than a silent `head -1`,
# because picking one would be picking which piece of work to inspect by
# accident -- and `show` and `diff` are how someone checks before acting.
resolve_entry() {
    local want=$1 all exact n
    all=$(find_entry "$want")
    [ -n "$all" ] || die "no entry matching '$want' in any namespace"

    exact=$(printf '%s\n' "$all" | awk -F'\t' -v w="$want" '$2 == w || $3 == w')
    if [ -n "$exact" ]; then
        printf '%s\n' "$exact" | first_line
        return
    fi

    n=$(printf '%s\n' "$all" | grep -c . || true)
    if [ "$n" -gt 1 ]; then
        die "$(printf "'%s' matches %s entries:\n%s" "$want" "$n" \
               "$(printf '%s\n' "$all" |
                  awk -F'\t' '{printf "    %-23s %-9s %s\n", $2, $1, $3}')")"
    fi
    printf '%s\n' "$all"
}

# The ref an entry lives at, needed to read its reflog.
entry_ref() {
    local state=$1 id=$2 branch=$3
    case "$state" in
        pending) printf '%s/%s/%s\n' "$PENDING_NS" "$id" "$branch" ;;
        merged)  printf '%s/%s/%s\n' "$DONE_NS" "$id" "$branch" ;;
        dropped) printf '%s/%s/%s\n' "$DROPPED_NS" "$id" "$branch" ;;
    esac
}

# One screen: where main is, whether anything can drain at all, and what is
# waiting. The three blockers are called out because a queue that is not
# moving is the thing you came here to understand.
cmd_status() {
    local mc depth id branch sha base tip ahead wt dirty orphan waiting flags

    mc=$(main_checkout)
    printf 'main checkout  %s\n' "$mc"
    printf "%-14s %s %s\n" "$MAIN" \
        "$(git rev-parse --short "$MAIN")" "$(git log -1 --format=%s "$MAIN")"

    # Reported, not treated as a blocker. A dirty main checkout only stops a
    # merge when the dirt is in a file the merge needs to write, and git says
    # so precisely when that happens -- so this is information, and the
    # fast-forward is the judge.
    dirty=$(git -C "$mc" status --porcelain | grep -c . || true)
    [ "$dirty" = 0 ] ||
        printf '               (%s uncommitted path%s; only blocks a merge that needs to write one)\n' \
            "$dirty" "$( [ "$dirty" = 1 ] || echo s )"

    if drain_in_progress; then
        printf '               DRAIN IN PROGRESS (%s)\n' "$(drain_lock)"
        printf '               -- or a drain died and left it behind; the queue\n'
        printf '                  refuses withdrawals until it is gone\n'
    fi

    depth=$(entries "$PENDING_NS" | grep -c . || true)
    printf 'pending        %s\n' "$depth"
    printf 'merged         %s\n' "$(entries "$DONE_NS" | grep -c . || true)"
    printf 'dropped        %s\n' "$(entries "$DROPPED_NS" | grep -c . || true)"

    [ "$depth" -gt 0 ] || return 0

    printf '\n%-23s %-26s %-14s %-7s %s\n' ID BRANCH SUBMITTED COMMITS WORKTREE
    entries "$PENDING_NS" | while IFS=$'\t' read -r id branch sha; do
        IFS=$'\t' read -r base tip < <(entry_range "$id" "$branch" "$sha")
        ahead=$(git rev-list --count "$base".."$tip" 2>/dev/null || echo '?')
        wt=$(worktree_for_branch "$branch")
        flags=''
        [ "$tip" = "$sha" ] || flags=' [branch moved since submitting]'
        orphan=$(orphaned_by "$base")
        [ -z "$orphan" ] ||
            flags="$flags [ORPHANED by $(printf '%s' "$orphan" | cut -f1)]"
        waiting=$(waiting_on "$base")
        [ -z "$waiting" ] ||
            flags="$flags [started from $(printf '%s' "$waiting" | cut -f4)]"
        printf '%-23s %-26s %-14s %-7s %s%s\n' \
            "$id" "$branch" \
            "$(ref_date "$PENDING_NS/$id/$branch")" \
            "$ahead" "${wt:--}" "$flags"
    done
}

# The commit on main an entry landed as, read back out of the provenance
# trailer its squash carries. Empty for an entry merged before the trailer
# existed: nothing on main names it, which is the reason the trailer was added.
#
# An exact prefix match on the id rather than a regex, since an id has dots in
# it and `20261013T221824.633546` would otherwise also match an id differing
# only in those positions. `separator=` so the value does not arrive with a
# trailing newline and split the pair the tab separates.
landed_commit() {
    local id=$1
    git log --format='%H%x09%(trailers:key=Queue,valueonly,separator=)' "$MAIN" 2>/dev/null |
        awk -F'\t' -v i="$id " 'index($2, i) == 1 { print $1; exit }'
}

# One entry in full. The pair of shas is the point for a merged entry: the
# rebase rewrote what was submitted, and this is the only place that says so.
cmd_show() {
    local entry state id branch sha base tip ref wt note orphan children msg landed
    local hparent hstate hid hbranch htag
    [ $# -ge 1 ] || die "show needs an id or branch, e.g. '${CLI}show ENTRY=api-fix'"
    entry=$(resolve_entry "$1")
    IFS=$'\t' read -r state id branch sha <<<"$entry"
    ref=$(entry_ref "$state" "$id" "$branch")

    printf 'entry      %s\n' "$id"
    printf 'state      %s\n' "$state"
    printf 'branch     %s%s\n' "$branch" \
        "$(git show-ref --verify --quiet "refs/heads/$branch" || echo '  (branch deleted)')"
    printf 'submitted  %s  %s\n' "$(git rev-parse --short "$sha")" \
        "$(ref_date "$ref" iso-strict)"

    IFS=$'\t' read -r base tip < <(entry_range "$id" "$branch" "$sha")
    if [ "$state" = pending ] && [ "$tip" != "$sha" ]; then
        printf 'will merge %s -- the branch has moved since it was submitted\n' \
            "$(git rev-parse --short "$tip")"
    fi

    orphan=$(orphaned_by "$base")
    [ -z "$orphan" ] || printf "ORPHANED   by withdrawn entry %s; rebase onto $MAIN before it can land\n" \
        "$(printf '%s' "$orphan" | tr '\t' ' ')"

    # A base that is a handover point is the one thing about an entry that
    # cannot be read off its commits: the range below it belongs to someone
    # else's branch, and whether it has landed is a queue question.
    hparent=$(handover_parent "$base")
    if [ -n "$hparent" ]; then
        IFS=$'\t' read -r hstate hid hbranch htag <<<"$hparent"
        printf 'started    from %s\n' "$htag"
        printf '           %s\n' "$(handover_state_line "$hstate" "$hid" "$hbranch")"
    fi

    if [ "$state" = pending ]; then
        children=$(pending_children_of "$sha" "$branch")
        [ -z "$children" ] || printf 'stacked on it: %s\n' \
            "$(printf '%s' "$children" | awk -F'\t' '{print $2}' | tr '\n' ' ')"
    fi

    if [ "$state" = merged ]; then
        landed=$(landed_commit "$id")
        if git merge-base --is-ancestor "$sha" "$MAIN" 2>/dev/null; then
            printf 'landed     %s unchanged -- nothing to rebase and nothing to squash\n' \
                "$(git rev-parse --short "$sha")"
        elif [ -n "$landed" ]; then
            printf 'landed     as %s, squashed into one commit; the commits below are\n' \
                "$(git rev-parse --short "$landed")"
            printf '           reachable only through %s\n' \
                "$(entry_ref merged "$id" "$branch")"
        else
            printf "landed     squashed into one commit on $MAIN; the commits below are\n"
            printf '           reachable only through %s\n' \
                "$(entry_ref merged "$id" "$branch")"
            printf "           it carries no Queue trailer, so $MAIN does not name it\n"
        fi
    fi

    wt=$(worktree_for_branch "$branch")
    printf 'worktree   %s\n' "${wt:-removed}"

    # The entry's description of itself, which for a pending entry is also a
    # preview of what main is about to say about it.
    msg=$(load_msg "$id" "$branch")
    if [ -n "$msg" ]; then
        printf '\nmerge message:\n'
        printf '%s\n' "$msg" | sed 's/^./  &/'
    else
        printf '\nmerge message: none recorded\n'
    fi

    if [ -n "$base" ]; then
        printf '\ncommits submitted (%s):\n' "$(git rev-list --count "$base".."$sha")"
        git log --reverse --format='  %h %s' "$base".."$sha"
        printf '\nfiles:\n'
        git diff --stat "$base" "$sha" | sed 's/^/  /'
    fi

    # The note lives on whatever the submitted commit became, so look for one
    # on every commit this entry put on main.
    if [ "$state" = merged ] && [ -n "$base" ]; then
        note=$(git log --format='%H' "$base".."$MAIN" 2>/dev/null |
               while read -r c; do
                   if git notes show "$c" >/dev/null 2>&1 &&
                      git notes show "$c" | grep -q "^merge-queue: $id "; then
                       printf '\nnote on %s:\n' "$(git rev-parse --short "$c")"
                       git notes show "$c" | sed 's/^/  /'
                   fi
               done)
        [ -z "$note" ] || printf '%s\n' "$note"
    fi
}

# What an entry was written against. The recorded base if there is one; for
# entries submitted before that was recorded, the live merge-base, which is
# still correct for anything not yet merged.
entry_base() {
    local id=$1 branch=$2 sha=$3
    if git show-ref --verify --quiet "$BASE_NS/$id/$branch"; then
        git rev-parse "$BASE_NS/$id/$branch"
    else
        git merge-base "$MAIN" "$sha" 2>/dev/null || true
    fi
}

# What an entry would bring to main, as a diff. Against the merge base rather
# than main's tip, so it shows the entry's own work and not the difference
# between the entry and everything merged since it was written.
cmd_diff() {
    local entry state id branch sha base tip
    [ $# -ge 1 ] || die "diff needs an id or branch, e.g. '${CLI}diff ENTRY=api-fix'"
    entry=$(resolve_entry "$1")
    IFS=$'\t' read -r state id branch sha <<<"$entry"
    IFS=$'\t' read -r base tip < <(entry_range "$id" "$branch" "$sha")
    [ -n "$base" ] || die "cannot tell what $id was written against"
    shift
    # The tip, so a pending entry's diff is what would actually land.
    git diff "$@" "$base" "$tip"
}

# main's own log, with the entry each commit came from read out of its `Queue:`
# trailer.
#
# The counterpart of `log` rather than a duplicate of it: `log` is what the
# queue remembers, assembled from refs that are local to this machine, and this
# is what main itself says, which is all a clone has. So an empty last column
# is a real finding -- the commit was made directly on main, or it landed
# before the squash carried a trailer.
#
# Arguments go to git log, so `make queue-history ARGS=-20` or
# `make queue-history ARGS=--since=2.weeks` narrows it.
cmd_history() {
    git log \
        --format='%h %<(50,trunc)%s %C(dim)%(trailers:key=Queue,valueonly,separator=)%C(reset)' \
        "$@" "$MAIN"
}

# An entry id, from anything that names an entry -- a branch, an id or an id
# prefix -- or from a commit, by the `Queue:` trailer the drain put on it.
#
# The commit form is what makes a line of `history` something you can follow:
# the squash left the entry's own commits off main, and the trailer is the only
# thing on main that says which entry a commit was. A commit without one did
# not come through the queue, and there is no entry to give.
entry_id_of() {
    local want=$1 trailer
    if [ -n "$(find_entry "$want")" ]; then
        resolve_entry "$want" | cut -f2
        return
    fi
    git rev-parse --verify --quiet "$want^{commit}" >/dev/null ||
        die "no entry and no commit matching '$want'"
    trailer=$(git log -1 --format='%(trailers:key=Queue,valueonly,separator=)' "$want^{commit}")
    [ -n "$trailer" ] ||
        die "commit $(git rev-parse --short "$want") has no Queue: trailer, so no entry landed it"
    printf '%s\n' "${trailer%% *}"
}

# The Claude Code project directories of the main checkout and its worktrees.
# Claude Code names each one after the path the session ran in, with a dash
# for every character that is not a letter or a digit -- so a worktree's is the
# main checkout's name followed by `--worktrees-<id>`, and the layout this
# script gives worktrees is what makes them findable from here at all.
transcript_dirs() {
    local root name d
    root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
    name=$(printf '%s' "$(main_checkout)" | tr -c 'A-Za-z0-9' '-')
    for d in "$root/$name" "$root/$name"--worktrees-*; do
        [ -d "$d" ] && printf '%s\n' "$d"
    done
    return 0
}

# The session transcripts that worked on an entry, subagents included.
#
# "Worked on" means the output of one of its commands names the entry id:
# `worktree` prints it, `submit` prints it, the drain prints it, and so does
# every review and `show` in between. Only a command's stdout and stderr count.
# A mention in a prompt, a skill or a file the session read does not, because
# that is a session talking ABOUT the entry rather than one the entry's work
# went through -- and an id quoted in a handover document would otherwise drag
# in every session that read the document.
#
# grep narrows the files first and jq decides, since the transcripts are large
# and the id is rare in them.
cmd_sessions() {
    [ $# -eq 1 ] || die "sessions needs an entry or a commit, e.g. '${CLI}sessions ENTRY=api-fix'"
    local id dirs f found=0
    command -v jq >/dev/null || die "sessions reads the transcripts with jq, which is not on PATH"
    id=$(entry_id_of "$1")
    dirs=$(transcript_dirs)
    [ -n "$dirs" ] || die "no Claude Code transcripts for $(main_checkout)"
    while read -r f; do
        if grep -F "$id" "$f" | jq -e --arg id "$id" \
            'select(.toolUseResult | objects | (.stdout // "") + (.stderr // "") | contains($id))' \
            >/dev/null 2>&1; then
            printf '%s\n' "$f"
            found=1
        fi
    done < <(printf '%s\n' "$dirs" | while read -r d; do
                 grep -rlF --include='*.jsonl' "$id" "$d" || true
             done | sort)
    [ "$found" = 1 ] || die "no transcript has a command whose output names entry $id"
}

# Each of those transcripts through `chaland audit`, one after another.
# Arguments after the entry go to chaland, ahead of the transcript.
#
# chaland is $CHALAND if that is set and `chaland` on PATH if not; the queue
# does not build or ship it. Every transcript is audited even when one fails,
# because the point is the set of them, and the failures are counted at the end.
cmd_audit() {
    [ $# -ge 1 ] || die "audit needs an entry or a commit, e.g. '${CLI}audit ENTRY=api-fix'"
    local want=$1 list chaland n=0 failed=0 f
    shift
    chaland=${CHALAND:-$(command -v chaland || true)}
    [ -n "$chaland" ] ||
        die "audit runs chaland, which is not on PATH; set CHALAND to the binary"
    list=$(cmd_sessions "$want")
    while read -r f; do
        n=$(( n + 1 ))
        printf '\n== %s\n' "$f"
        "$chaland" audit "$@" "$f" || failed=$(( failed + 1 ))
    done <<<"$list"
    [ "$failed" = 0 ] || die "$failed of $n audit(s) did not finish"
}

# Every conflict resolution the draining agent has recorded, newest first.
# The notes are on main's commits; this is the queue's side of that history.
cmd_notes() {
    local found=0 c
    while read -r c; do
        if git notes show "$c" >/dev/null 2>&1 &&
           git notes show "$c" | grep -q '^merge-queue: '; then
            found=1
            printf '=== %s %s\n' "$(git rev-parse --short "$c")" "$(git log -1 --format=%s "$c")"
            git notes show "$c" | sed 's/^/    /'
            printf '\n'
        fi
    done < <(git log --format='%H' "$MAIN")
    [ "$found" = 1 ] || echo "no merge-queue notes on $MAIN -- nothing has conflicted yet"
}

# Replay the queue onto main without landing it, to find out where it will
# conflict before the draining agent gets there.
#
# This is the conflicting half of what the drain does -- the same rebase of the
# same range, in the same order, cumulatively -- so a clean result here means a
# clean drain, and a conflict here is the conflict that agent will meet. The
# drain then squashes each entry's replayed commits into one; nothing about
# that can conflict, so there is nothing here to predict about it. Like the drain it
# replays the branch TIP, so an entry whose branch has moved since submission
# is checked as it will actually be merged. It stops at the first conflict for
# the same reason the drain does: everything after an entry was written against
# it landing, so checking past a blockage would report conflicts that exist
# only in a future that will not happen.
cmd_check() {
    local only=${1:-} cw mc id branch sha base tip orphan waiting conflicted rc=0
    local replayed=' ' pid

    mc=$(main_checkout)
    drain_in_progress &&
        die "a drain is in progress ($(drain_lock)); not touching the queue"

    if [ -z "$(entries "$PENDING_NS")" ]; then
        echo "queue is empty -- nothing to check"
        return 0
    fi

    # Before building anything: an id that matches no pending entry is a typo,
    # and reporting it after creating and removing a worktree reads like the
    # check ran and found nothing wrong.
    if [ -n "$only" ]; then
        only=$(pending_for_id "$only" | cut -f1)
        [ -n "$only" ] || die "no pending entry matching '${1:-}'"
    fi

    # One scratch worktree per run, named with the id format a submission uses,
    # because the name used to be the fixed `.queue-check`: two agents checking
    # at once both wanted that path, and the one that arrived second
    # force-removed the first's worktree from under a running rebase. The first
    # check then failed in a way that looked like a conflict in someone's
    # branch.
    #
    # `git worktree add` refuses a path that already exists, which is the same
    # must-not-exist precondition `claim_id` leans on -- so two runs in one
    # microsecond collide loudly and harmlessly, and the answer is to run it
    # again. No ref is claimed, because this is not an entry and nothing should
    # later read it as one.
    cw="$mc/.worktrees/.queue-check-$(new_id)"
    stale_checks "$mc"
    git worktree add -q --detach "$cw" "$MAIN"
    # Removed on every exit path, including the rebase leaving it mid-operation
    # and the shell being interrupted part-way through one.
    #
    # Double quotes, so $cw is expanded NOW and baked into the trap. Single
    # quotes defer it to when the trap fires, and by then this function has
    # returned and `cw` is a local that no longer exists -- under `set -u` the
    # cleanup then dies on an unbound variable and leaves behind the very
    # worktree it exists to remove.
    trap "git -C '$cw' rebase --abort >/dev/null 2>&1 || true
          git worktree remove --force '$cw' >/dev/null 2>&1 || true" EXIT INT TERM

    if [ -n "$only" ]; then
        printf "replaying %s onto $MAIN (%s)\n\n" "$only" "$(git rev-parse --short "$MAIN")"
    else
        printf "replaying the queue onto $MAIN (%s), cumulatively\n\n" \
            "$(git rev-parse --short "$MAIN")"
    fi

    while IFS=$'\t' read -r id branch sha; do
        if [ -n "$only" ] && [ "$id" != "$only" ]; then
            continue
        fi
        IFS=$'\t' read -r base tip < <(entry_range "$id" "$branch" "$sha")

        # An orphan is reported without being replayed. Replaying it would
        # usually succeed, and that success would be the misleading part: the
        # commits apply cleanly onto a main that never receives what they were
        # written against.
        orphan=$(orphaned_by "$base")
        if [ -n "$orphan" ]; then
            printf '  %-23s %-26s ORPHANED\n' "$id" "$branch"
            printf '           written on top of withdrawn entry %s\n' \
                "$(printf '%s' "$orphan" | tr '\t' ' ')"
            printf "           rebase it onto $MAIN before it can land\n"
            rc=1
            [ -n "$only" ] || { printf '\nstopped at %s.\n' "$id"; break; }
            continue
        fi

        # Work this entry was started from that main has not got -- unless this
        # run has already replayed it. The check is cumulative: it replays
        # entries in merge order onto one another, so a parent earlier in the
        # order is present in the scratch worktree by the time its child is
        # replayed, exactly as it will be present on main by the time the drain
        # reaches the child. Asking "is it on main yet" here would report every
        # correctly ordered stack as blocked.
        waiting=$(waiting_on "$base")
        if [ -n "$waiting" ]; then
            pid=$(printf '%s' "$waiting" | cut -f2)
            case "$replayed" in
                *" $pid "*) waiting='' ;;
            esac
        fi
        if [ -n "$waiting" ]; then
            printf '  %-23s %-26s WAITING\n' "$id" "$branch"
            printf '           %s\n' "$(waiting_report "$waiting")"
            printf '           it cannot land until that does\n'
            rc=1
            [ -n "$only" ] || { printf '\nstopped at %s.\n' "$id"; break; }
            continue
        fi

        if git -C "$cw" rebase --onto HEAD "$base" "$tip" >/dev/null 2>&1; then
            replayed="$replayed$id "
            printf '  %-23s %-26s clean%s\n' "$id" "$branch" \
                "$( [ "$tip" = "$sha" ] || echo '  [branch moved since submitting]' )"
        else
            conflicted=$(git -C "$cw" diff --name-only --diff-filter=U)
            git -C "$cw" rebase --abort >/dev/null 2>&1 || true
            printf '  %-23s %-26s CONFLICT\n' "$id" "$branch"
            printf '%s\n' "$conflicted" | sed 's/^/           /'
            rc=1
            if [ -z "$only" ]; then
                printf '\nstopped at %s. Entries after it are not checked: a blocked entry\n' "$id"
                printf "blocks the queue, so what follows it would be replayed onto a $MAIN\n"
                printf 'that never happens.\n'
                break
            fi
        fi
    done < <(entries "$PENDING_NS")

    if [ "$rc" = 0 ]; then
        if [ -n "$only" ]; then
            printf "\n%s replays clean onto $MAIN as it is now -- which is not a\n" "$only"
            printf 'promise about the drain, because entries ahead of it land first.\n'
        else
            printf "\nthe whole queue replays clean onto $MAIN\n"
        fi
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Merging
#
# One entry, by hand, when nothing conflicts. The drain proper is an agent --
# `/merge-queue` -- because resolving a conflict is a judgement about someone
# else's code and a shell script has none. What is left when there is no
# conflict is purely mechanical, and that is what this is: the same replay, the
# same squash, the same fast-forward, the same cleanup, and a refusal the
# moment anything needs deciding.
# ---------------------------------------------------------------------------

# Land one pending entry on main, if it replays cleanly.
#
# With no argument it takes the head of the queue, which is the entry the drain
# would take. Named, it will merge an entry out of order -- the queue's order is
# what a drain follows, not a law about which finished work may land -- but it
# refuses the two cases where out of order is not merely early but wrong: an
# ORPHAN, whose base was withdrawn, and an entry STACKED on something still
# pending. Both of those replay perfectly cleanly onto a main that never
# received what they were written against, so a clean rebase is no evidence at
# all and the breakage arrives silently.
#
# A conflict is a full stop rather than a prompt. Nothing here is equipped to
# resolve one, and a resolution is exactly what has to be recorded as a note --
# so it aborts, leaves the entry pending, names the files, and sends you to
# `/merge-queue`, which can do both.
cmd_merge() {
    local want=${1:-} entry id branch sha base tip orphan parent ahead waiting
    local mc lock wt wtp cwd msg squashed conflicted log keep=''

    mc=$(main_checkout)

    if drain_in_progress; then
        die "$(cat <<EOF
a drain is in progress, so the queue is not accepting merges.

Wait for it to finish. If no drain is actually running, it died and left its
worktree behind -- inspect it, since it may hold a half-finished rebase, then:

    git worktree remove --force $(drain_lock)
EOF
)"
    fi

    if [ -n "$want" ]; then
        entry=$(pending_for_id "$want") || true
        [ -n "$entry" ] || die "no pending entry matching '$want'"
        IFS=$'\t' read -r id branch sha <<<"$entry"
    else
        IFS=$'\t' read -r id branch sha < <(entries "$PENDING_NS") || true
        [ -n "${id:-}" ] || { echo "queue is empty -- nothing to merge"; return 0; }
    fi

    # main has to be the thing the fast-forward moves. Checked before any work
    # is done rather than discovered at the end, when the replay and the squash
    # have already happened and only the landing fails.
    [ "$(git -C "$mc" symbolic-ref --quiet --short HEAD || true)" = "$MAIN" ] ||
        die "$mc does not have $MAIN checked out; the queue merges into $MAIN there"

    IFS=$'\t' read -r base tip < <(entry_range "$id" "$branch" "$sha")
    [ -n "$base" ] || die "cannot tell what $id was written against"

    orphan=$(orphaned_by "$base")
    if [ -n "$orphan" ]; then
        die "$(printf '%s\n\n%s\n' \
            "$id ($branch) is ORPHANED by withdrawn entry $(printf '%s' "$orphan" | tr '\t' ' ')" \
            "It would replay onto a $MAIN that never receives what it was written against, which is the kind of breakage a clean rebase hides. Rebase it onto $MAIN first.")"
    fi

    # The same question for a handover base, which `pending_under` cannot see:
    # that base is a commit in the MIDDLE of another branch, so it is nobody's
    # submitted tip.
    waiting=$(waiting_on "$base")
    if [ -n "$waiting" ]; then
        die "$(printf '%s %s\n\n%s\n' \
            "$id ($branch)" "$(waiting_report "$waiting")" \
            "That work is not on $MAIN. Land it first, or rebase this onto $MAIN: replaying this entry alone would put commits on $MAIN that were written against a commit $MAIN has never seen -- cleanly, and wrongly.")"
    fi

    # Nothing may still be in the queue underneath this entry. Replaying it
    # alone would land commits written on top of work that main has not got --
    # cleanly, because the two touch different lines, and wrongly.
    parent=$(pending_under "$tip" "$id")
    if [ -n "$parent" ]; then
        die "$(printf '%s\n\n%s\n' \
            "$id ($branch) is stacked on $(printf '%s' "$parent" | tr '\t' ' '), which has not landed yet" \
            "Merge that entry first. This one contains its commits, so replaying it alone would put work on $MAIN that was written against something still sitting in the queue.")"
    fi

    # The author's, never invented here. An entry with nothing to say about
    # itself is the one thing a merge cannot supply.
    msg=$(load_msg "$id" "$branch")
    [ -n "$msg" ] || die "$(printf '%s\n\n    %s\n' \
        "$id ($branch) has no merge message, so its commit on $MAIN would have nothing to say" \
        "M=\"<subject>\" ${CLI}message ENTRY=$branch")"

    # Captured before anything is deleted, and before the branch is gone.
    wt=$(worktree_for_branch "$branch")

    ahead=$(entries "$PENDING_NS" | awk -F'\t' -v i="$id" '$1 < i' || true)
    if [ -n "$ahead" ]; then
        printf 'merging out of order, ahead of:\n'
        printf '%s' "$ahead" | awk -F'\t' '{printf "    %s  %s\n", $1, $2}'
    fi

    # The lock, taken the way a drain takes it: the directory's existence is
    # what stops a second merge, and what makes `drop` refuse meanwhile.
    lock="$mc/.worktrees/.merge-queue"
    git worktree add -q --detach "$lock" "$MAIN" ||
        die "cannot take the drain lock at $lock"
    # Double quotes: $lock is expanded now and baked in. Deferred, it would be
    # read after this function returned, when the local no longer exists, and
    # `set -u` would kill the cleanup that exists to remove the worktree.
    trap "git -C '$lock' rebase --abort >/dev/null 2>&1 || true
          git worktree remove --force '$lock' >/dev/null 2>&1 || true" EXIT INT TERM

    printf "replaying %s (%s) onto $MAIN (%s)\n" \
        "$id" "$branch" "$(git rev-parse --short "$MAIN")"

    if ! git -C "$lock" rebase --onto HEAD "$base" "$tip" >/dev/null 2>&1; then
        conflicted=$(git -C "$lock" diff --name-only --diff-filter=U)
        git -C "$lock" rebase --abort >/dev/null 2>&1 || true
        git worktree remove --force "$lock" >/dev/null 2>&1 || true
        trap - EXIT INT TERM
        printf 'CONFLICT in %s (%s):\n' "$id" "$branch" >&2
        printf '%s\n' "$conflicted" | sed 's/^/    /' >&2
        die "$(printf '%s\n\n%s\n' \
            "left pending, and $MAIN is untouched." \
            "Resolving this is a judgement about someone else's code and has to be recorded as a git note, which is what the draining agent is for: run /merge-queue.")"
    fi

    # One commit on main per entry: the replayed commits are the author's
    # working steps, and main takes the change rather than the steps.
    git -C "$lock" reset --soft "$MAIN" >/dev/null
    # stdout to /dev/null, stderr kept: the only expected failure here is
    # "nothing to commit", which git reports on stdout and which the die below
    # says better. A real one still has somewhere to be seen.
    landing_msg "$id" "$branch" "$sha" |
        git -C "$lock" commit -q -F - \
            --author="$(git log -1 --format='%an <%ae>' "$tip")" >/dev/null ||
        die "nothing to commit: $id ($branch) contributes nothing $MAIN does not already have"
    squashed=$(git -C "$lock" rev-parse HEAD)

    # As the drain does: the tree as it will land, before main moves to it.
    if [ -n "$TEST" ]; then
        printf 'testing: %s\n' "$TEST"
        if ! log=$(test_entry "$lock" "$id"); then
            tail -n 15 "$log" | sed 's/^/    /' >&2
            die "$(printf '%s\n\n%s\n' \
                "$id ($branch) replayed cleanly but failed $TEST; left pending, and $MAIN is untouched." \
                "In full: $log")"
        fi
    fi

    # --ff-only is the only check on the state of the main checkout, and it is
    # enough: it refuses exactly when the merge would overwrite a modified or
    # untracked file, and names the file. Its own message is the report.
    git -C "$mc" merge --ff-only "$squashed" >/dev/null ||
        die "$id ($branch) replayed cleanly but $MAIN would not fast-forward (see above); left pending"

    cmd_complete "$id" >/dev/null
    git worktree remove --force "$lock" >/dev/null 2>&1 || true
    trap - EXIT INT TERM

    printf 'merged %s %s as %s\n' "$id" "$branch" "$(git rev-parse --short "$squashed")"
    printf "$MAIN now at %s %s\n" \
        "$(git rev-parse --short "$MAIN")" "$(git log -1 --format=%s "$MAIN")"

    # Cleanup is the drain's, and so are its guards: it removes the worktree
    # and the branch, and it skips either the moment doing so would destroy
    # something. Landing is never skipped -- the work is on main by here, and
    # the worst a skipped cleanup costs is a directory left behind.
    cwd=$(pwd -P)
    if [ -n "$wt" ]; then
        wtp=$(cd "$wt" 2>/dev/null && pwd -P) || wtp=$wt
        case "$cwd/" in
            "$wtp"/*) keep='you are standing in it' ;;
        esac
        [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] ||
            keep='it has uncommitted changes'
    fi
    [ "$(git rev-parse "$branch" 2>/dev/null || echo "$tip")" = "$tip" ] ||
        keep='the branch moved while it was being merged'

    if [ -n "$keep" ]; then
        printf '\nworktree and branch kept: %s.\n' "$keep"
        [ -z "$wt" ] || printf '    git worktree remove --force %s\n' "$wt"
        printf '    git branch -D %s\n' "$branch"
        printf 'The entry is merged either way; those commits live on at %s.\n' \
            "$(entry_ref merged "$id" "$branch")"
        return 0
    fi

    [ -z "$wt" ] || git worktree remove --force "$wt"
    # -D, not -d: the rebase rewrote these commits and the squash replaced
    # them, so -d refuses even though everything landed. The tip comparison
    # above is the safety check -d would otherwise have done.
    git show-ref --verify --quiet "refs/heads/$branch" && git branch -q -D "$branch" || true
    printf 'cleaned up: %s%s\n' "${wt:+$wt, }" "branch $branch"
}

case "${1:-list}" in
    list)     shift || true; cmd_list ;;
    log)      shift || true; cmd_log ;;
    status)   shift || true; cmd_status ;;
    show)     shift || true; cmd_show "$@" ;;
    diff)     shift || true; cmd_diff "$@" ;;
    notes)    shift || true; cmd_notes ;;
    history)  shift || true; cmd_history "$@" ;;
    sessions) shift || true; cmd_sessions "$@" ;;
    audit)    shift || true; cmd_audit "$@" ;;
    check)    shift || true; cmd_check "$@" ;;
    next)     shift || true; cmd_next ;;
    id)       shift || true; cmd_id ;;
    worktree) shift || true; cmd_worktree "$@" ;;
    handover) shift || true; cmd_handover "$@" ;;
    submit)   shift || true; cmd_submit "$@" ;;
    message)  shift || true; cmd_message "$@" ;;
    landing-message) shift || true; cmd_landing_message "$@" ;;
    complete) shift || true; cmd_complete "$@" ;;
    drop)     shift || true; cmd_drop "$@" ;;
    drain)    shift || true; cmd_drain "$@" ;;
    merge)    shift || true; cmd_merge "$@" ;;
    *)        die "unknown command: $1 (worktree, handover, list, status, show, diff, check, notes, history, sessions, audit, log, submit, message, landing-message, drop, drain, merge, next, id, complete)" ;;
esac
