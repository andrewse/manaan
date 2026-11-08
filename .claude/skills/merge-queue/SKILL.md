---
name: merge-queue
description: Drain the merge queue into the target branch — squash each submitted worktree on in submission order, resolve conflicts, record each resolution as a git note, and clean up. Run in a dedicated session, usually under /loop. Use when asked to drain, watch or process the merge queue, or to merge submitted worktrees.
---

# Draining the merge queue

You are the only thing that writes to the target branch (`main`, unless this
repository set `QUEUE_MAIN`). Worktrees are submitted to a queue by
`/worktree-task`; you merge them, **in submission order**, one at a time, and
you record what you had to decide.

The queue is `queue/queue.sh`, driven by the `queue-*` targets in
`queue/queue.mk`; `make queue-help` lists them. **Run them from the repository
root** — this work all happens in the main checkout, which is where the
Makefile is, and `make` does not search upward for one.

`make queue-drain` does the mechanical half: for each pending entry it replays
the entry's own commits on, squashes them into **one commit** under the message
its author submitted, fast-forwards the branch, marks the entry drained, and
deletes the branch and its worktree. The log therefore reads as one commit per
change rather than one per step, and that message is the only thing the branch
says about the entry — which is why you never write it yourself.

To it the drain appends one trailer, `Queue: <id> <branch> <submitted sha>`,
which is the only thing on the branch that names the entry a commit came from.
Every `refs/merge-queue*` ref is local to this machine, so on a clone the
trailer is the whole of the provenance.

What `drain` will not do is **decide anything**. It stops at the first entry
that needs a judgement and leaves it pending. That is what you are for: you
resolve the conflict it stopped on, record the resolution as a git note, and
start it again. Everything `drain` lands, it lands the same way every time, and
nothing you do by hand should be a step it could have taken itself.

Run this in its own session, in the **main checkout** — not in a worktree:

```
/loop /merge-queue
```

Under `/loop` you wake, drain whatever is there, and sleep. An empty queue is
the normal finding, not a problem: report it as a no-op and go back to sleep.
Without `/loop` it is a single drain and exit.

## The invariants

1. **Order is absolute.** Lowest id first, always. Never reorder to get an
   easy merge first, never skip a hard entry to make progress.
2. **One at a time, and one drain at a time.** An entry is fully landed and
   cleaned up before the next is looked at, and `.worktrees/.merge-queue` makes
   sure only one agent is doing this at all.
3. **A blocked entry blocks the queue.** If you cannot land the head entry,
   stop, leave it pending, and report. Do not move on to the next one — the
   whole point of a queue is that what follows was written against what
   precedes it.
4. **Every conflict gets a note.** A resolution nobody recorded is a silent
   decision about someone else's code.
5. **You do not change the work.** You resolve conflicts and nothing else. If
   an entry needs real edits to be correct, it is blocked, not fixable here.
6. **You never delete work you did not land.** This is why the drain takes the
   branch tip rather than the commit pinned at submission: the cleanup deletes
   the branch, and anything left out would go with it, unreachable and not in
   any reflog. The squash makes this sharper — the entry's own commits are not
   on the target branch at all, and once the branch is gone
   `refs/merge-queue-done/<id>/<branch>` is the only thing holding them.
7. **The message is the author's.** It is committed as given, with only the
   `Queue:` trailer appended — which is the queue's own line about where the
   commit came from, not a word about what the change does. If the message does
   not describe what the entry does, that is theirs to fix with
   `make queue-message`, not yours to rewrite.

## Before you start

```bash
git switch main            # or whatever this repository's target branch is
make queue-status          # where it is, what is waiting, and what is stuck
```

`queue-status` prints the branch's position, the depth of the queue, when each
entry was submitted, whether any branch has moved since, and whether any entry
is orphaned. Two things in it need judgement:

- **`.worktrees/.merge-queue` already present.** Either another drain is
  running — in which case stop, there must only ever be one — or a previous
  drain was interrupted. `drain` refuses while it exists, and that refusal is
  right until you have looked: it may be sitting in a half-finished rebase
  whose resolutions are worth keeping. Check `git log` on the target branch
  against the head entry too, because an interrupted drain can have landed the
  squash commit without marking the entry drained. The squash landed and the
  entry still pending means it needs `make queue-complete ENTRY=<id>`, not
  another drain: replaying the range would try to apply patches whose content
  the branch already has.
- **uncommitted paths in the main checkout.** Reported, not a blocker. A dirty
  checkout only stops a merge that needs to write one of those exact paths, and
  the fast-forward reports that precisely when it happens. Do not tidy someone
  else's working tree to make the number go away.

Then, if you want to know what is coming before committing to it:

```bash
make queue-check           # replay the whole queue, cumulatively
```

That is the same replay in the same order, in a scratch worktree it cleans up,
touching neither the target branch nor the entries. It stops at the first
conflict and names the files. It is optional — `drain` finds the same conflicts
in the same place — but it turns "something in this batch will conflict" into a
known fact before anything has landed.

## The VM tests: yours, and only for entries that could affect them

The VM tests — `<host>`, `<host>-installer` and `<host>-upgrade` for each host
in `hosts/` — are this repository's expensive check: on this Mac they boot
emulated VMs in Docker, and take the best part of an hour per host. So nobody
else runs them. Worktree agents and reviewers leave them to you, and you run
them only on an entry whose changes could affect them. `queue-drain` and
`queue-merge` never run them, so which way an entry lands depends on this.

Take the queue **one entry at a time**, and for the head entry ask whether it
touches anything that could change a VM test:

```bash
next=$(make queue-next)
base=$(printf '%s' "$next" | cut -f5); tip=$(printf '%s' "$next" | cut -f6)
git diff --name-only "$base" "$tip" -- . \
    ':!*.md' ':!queue/' ':!.claude/' ':!.github/' ':!.gitignore'
```

- **Nothing listed** — it cannot affect them. `make queue-merge` lands it, and
  stops where `drain` would; the blockages are under **Drain it**, below.
- **Anything listed** — land it by hand, as under **Landing the entry a
  conflict stopped, by hand**, with the VM tests as step 4. Without a conflict,
  step 3 and step 7 have nothing to do. A failing test blocks the entry like a
  semantic conflict does: abort, leave it pending, and report the test and the
  lines of its log that show why.

The pathspec is a list of what **cannot** affect the tests, so anything not on
it — a new top-level directory included — runs them. Add to it only what no Nix
file reads. Err towards running them: a skipped test that would have failed
lands on `main` unseen.

`make queue-drain` lands every entry without running anything, so it is for a
queue where every pending entry has come back with nothing listed, and not
otherwise.

## Drain it

```bash
make queue-drain
```

One line per entry: `squashed to <sha>`, or what stopped it. It stops at the
first blockage, leaves that entry pending, and exits non-zero. Entries that
already landed stay landed; entries behind the blockage are not touched,
because they were written against the one that is stuck.

```
draining onto main (2ec351a)

  20261013T114729.172739  feat-c                     squashed to 6f1c7d3
  20261013T114729.411830  feat-d                     CONFLICT
           g.txt
           left pending, and main untouched: resolving it is /merge-queue work

landed 1, main now at 6f1c7d3, 2 still pending
```

Clean to the end — `landed N, ... 0 still pending` — and you are done: report
and sleep. Otherwise read what stopped it, because only one of the six kinds
of blockage is yours to fix.

- **CONFLICT.** Yours. The files are named. Land that one entry by hand, below,
  then carry on with the queue from **The VM tests**, above.
- **ORPHANED.** A full stop. The entry was written on top of an entry that was
  *withdrawn*, so what it depends on will never land. Do not merge it and do
  not try to resolve it: orphaned work usually replays perfectly cleanly and is
  wrong anyway. Report it, and say it needs rebasing onto the target branch.
- **started from work that has not landed.** A full stop, and the same kind of
  wrongness as an orphan with a different cause: the entry was started from a
  *handover point* on another branch, and that branch's work has not landed, so
  replaying this entry would put commits on the target branch that were written
  against a commit it has never seen. Reaching this in submission order should
  be impossible — the entry below it was submitted first — so it means the
  order was inverted. Land the entry it names first, through **The VM tests**
  like any other (`make queue-merge ENTRY=<entry>` will take it out of order),
  then carry on from there. If the work it names is not in the queue at all,
  report it: the author has to submit it or rebase.
- **no merge message.** A full stop. There is nothing for the squash commit to
  say, and inventing one would put your description of someone else's change on
  the target branch for good. Report it and ask the author for
  `M="..." make queue-message ENTRY=<entry>`.
- **replays to nothing.** The entry's tree is already the target branch's — the
  work arrived some other way, or there was never any. Do not force an empty
  commit. Report that it contributes nothing; withdrawing it with
  `make queue-drop ENTRY=<entry>` is the author's call.
- **the fast-forward refused.** Git's message is printed verbatim and names the
  file: a modified tracked file, or an untracked file in the way, in the main
  checkout. That is somebody's working tree, not yours to clear. Report it as
  blocked. The replay and the squash both happened in a scratch worktree, so
  nothing is lost but time.

`make queue-merge` is that same sequence for a **single** entry: the head of
the queue by default, or `ENTRY=<entry>` out of order — though never an orphan,
and never one stacked on an entry that has not landed. It stops where `drain`
stops and resolves nothing either, so an entry it will not take is an entry you
land by hand. A whole queue is `drain`'s job; reach for `merge` when you want
one entry and no more.

## Landing the entry a conflict stopped, by hand

This is the same sequence `drain` runs, with your resolution in the middle of
it. Do all of it for **one** entry — the head of the queue — and then go back
to **The VM tests**, above, for the next.

### 1. Take the lock, then read the entry

`.worktrees/.merge-queue` **is** the lock. Create it first, before reading the
queue — the second drain to try fails, which is what stops two agents merging
at once, and `queue-drop` refuses while it exists, which is what stops an
author withdrawing an entry from under you. Read first and lock second and
there is a gap in which both can still happen.

```bash
git worktree add --detach .worktrees/.merge-queue main   # the lock
make queue-next   # id, branch, sha, worktree, base, tip, orphan, waiting
                  # TAB-separated; empty output = empty queue, done
make queue-message ENTRY="$id"   # the message its squash commit will carry
```

If `worktree add` fails because the path exists, stop: another drain holds it,
or an interrupted one left it. Do not force past it.

Read the entry into `id`, `branch`, `sha`, `wt`, `base`, `tip`, `orphan`,
`waiting`. Three of those columns are empty in ordinary cases, so split the
line on tabs by position — `cut -f4` and so on — and not with
`IFS=$'\t' read`, which collapses two adjacent tabs into one delimiter and
hands you `base` where `wt` should be.

- **`waiting` must be empty before you merge anything.** It names a handover
  point this entry was started from whose work has not landed; replaying this
  entry alone would land commits written against a commit the target branch has
  never seen, cleanly and wrongly. Land that work first, out of order if need
  be.

- **Merge `tip`, record `sha`.** `tip` is where the branch stands now; `sha` is
  what was pinned at submission. They differ whenever the author committed again
  after submitting, which is ordinary — and merging the tip is what stops your
  own cleanup in step 8 from deleting those commits. `sha` remains what the
  done ref and the note record.
- **Use `base` as given; do not re-derive it.** Both obvious substitutes are
  wrong. `git merge-base main "$tip"` replays a **stacked** entry's parent a
  second time, because that branch contains its parent's commits too. The
  submitted `sha` throws away the late commits. `make queue-next` has already
  worked the range out, including for a branch rebased since submission.

### 2. Replay the entry's commits on, in that worktree

Never rebase in the author's worktree: it is not yours, and resetting it would
destroy work committed after submission.

```bash
git -C .worktrees/.merge-queue rebase --onto HEAD "$base" "$tip"
```

That replays exactly the entry's own commits — `base..tip` — onto the target
branch. It is the same command `queue-drain` and `queue-check` run, which is
what makes a clean check a trustworthy prediction of a clean drain.

A rebase even though the result is squashed, and for two reasons. It resolves
conflicts **one commit at a time**, in the steps the author wrote, which is far
more tractable than meeting every collision in the branch at once — and it
keeps all three paths replaying the same range with the same command. Step 5
collapses the replayed commits afterwards; nothing about that can conflict.

No merge commit either way: queue order reads directly as commit order on the
target branch, rather than hiding behind "Merge branch ...".

### 3. Resolve conflicts

```bash
git -C .worktrees/.merge-queue diff --name-only --diff-filter=U
```

Resolve each file, `git add` it, then
`GIT_EDITOR=true git -C .worktrees/.merge-queue rebase --continue`. Repeat
until the rebase completes. Keep a note of every file you touched and what you
decided — you are about to write it down.

Resolve by intent, not by side. Read what each side was trying to do, from both
commit messages, and produce the thing that does both. Taking "ours" or
"theirs" wholesale is almost always wrong; when one side genuinely supersedes
the other, that is a fact worth stating in the note.

If resolution would mean changing what the code does — a semantic conflict, a
test that cannot pass either way — stop:

```bash
git -C .worktrees/.merge-queue rebase --abort
git worktree remove --force .worktrees/.merge-queue
```

The entry stays pending. Report what collided and why you could not decide it.

### 4. Check it before it lands

Run the checks the parts of the repository involved actually have — their test
command, their linter, their build — before squashing anything on. For a change
to the queue itself that is `make queue-selftest`. A resolution that compiles in
your head is not a resolution. This step is why landing a conflict is yours and
not `drain`'s.

For an entry that could affect the VM tests (**The VM tests**, above), they are
part of this step, run on the replayed tree in the lock worktree, one host at a
time:

```bash
for h in $(ls hosts); do
    caffeinate -i make -C .worktrees/.merge-queue test-local HOST="$h" || break
done
```

`caffeinate -i` because Docker Desktop's VM is paused while the Mac sleeps, and
a run left overnight goes nowhere. The lock is held throughout, which is
right: nothing may land, and nothing may be withdrawn, while the tree that
will land is being tested. A conflict you resolved in an affected entry is
tested like any other change to it.

Failing checks after a resolution means the entry is blocked: abort as above
and report.

### 5. Squash it into one commit

The replayed commits are the author's working steps. The target branch takes
one commit, and its message is the one the author submitted:

```bash
git -C .worktrees/.merge-queue reset --soft main
make queue-landing-message ENTRY="$id" |
    git -C .worktrees/.merge-queue commit -F - \
        --author="$(git log -1 --format='%an <%ae>' "$tip")"
```

`queue-landing-message`, not `queue-message`. `queue-message` is the author's
text; `queue-landing-message` is that text plus the `Queue:` trailer naming the
entry, and it is what `drain` commits. Pipe the other one in and the entry lands
with nothing on it saying which entry it was — and on the entries where that
matters most, since these are the ones somebody had to decide something about.

`reset --soft` moves HEAD back to the target branch and leaves the replayed tree
in the index, so the commit that follows is that tree in a single step.
`--author` keeps the work attributed to whoever wrote it; you are the committer,
which is what records that the queue put it there.

`commit` refusing with nothing to commit means the entry's tree is already the
target branch's. Do not force an empty commit: abort as in step 3, leave the
entry pending, and report that it contributes nothing.

Everything the squash discards is still reachable through the branch until
step 8 deletes it, and through `refs/merge-queue-done/<id>/<branch>` afterwards.

### 6. Fast-forward the target branch

Capture the squash commit first — you need its hash for the note, and after the
fast-forward the scratch worktree is gone.

```bash
squashed=$(git -C .worktrees/.merge-queue rev-parse HEAD)
git merge --ff-only "$squashed"
```

Leave the worktree in place until step 8 — it is the lock.

`--ff-only` is the safety rail, and it is also the **only** check on the state
of the main checkout. It refuses when the merge would overwrite a modified
tracked file or an untracked file in its way, and it names the file when it
does. Nothing pre-screens for that: an unrelated dirty file cannot affect the
merge, and a pre-screen that blocked on one would stop the queue for nothing.
If `--ff-only` refuses, report git's message verbatim and treat the entry as
blocked.

### 7. The note

One note, on the squash commit, with a block per file you had to decide:

```bash
git notes add -m "$(cat <<'EOF'
merge-queue: 20261013T114729.172739 api-named-queries
submitted: 7e90326313beeb467f10d2d21cc7ee8cba4154d7

Conflict: Makefile
  Both sides appended a target at the end of the file -- the entry below
  added `deploy`, this branch added `api-named-queries`.
  Resolution: kept both, in queue order, the earlier entry's first.
  Independent targets, so there was nothing to choose between.

Conflict: api/internal/detect/detect.go
  The entry below renamed detectFormat to classify. This branch added a
  new caller of detectFormat, written before the rename existed.
  Resolution: took the rename and pointed the new caller at classify().
  Verified with the package's own tests.
EOF
)" "$squashed"
```

The shape: the queue entry and the submitted sha in the header, then one block
per file. The commit's `Queue:` trailer now carries that same pair, so the
header is no longer the only record of what was submitted; it stays because a
note is read on its own, and one that opens by saying which entry it belongs
to does not need the commit read first. Each block says **what the two sides
did** and **what you kept and why**. "Resolved conflict in Makefile" is not a
note; it is the absence of one.

One note, not one per conflicted commit: the entry is one commit now, so every
resolution in it hangs there. Name the file in each block, since the commit no
longer divides the work into steps.

`git log` shows notes from `refs/notes/commits` with no extra flags, which is
why they go there. They are not pushed by default — `git push origin
refs/notes/commits` if the user wants them shared.

A note is only ever written here. An entry `drain` landed by itself had nothing
to decide, so it has nothing to record.

### 8. Mark it drained, release the lock, clean up

Only after the squash commit is actually on the target branch:

```bash
make queue-complete ENTRY="$id"
git worktree remove --force .worktrees/.merge-queue      # release the lock

[ -z "$wt" ] || git worktree remove --force "$wt"        # may already be gone
if [ "$(git rev-parse "$branch" 2>/dev/null)" = "$tip" ]; then
    git branch -D "$branch"
else
    echo "branch $branch kept: it moved again during the drain"
fi
```

`queue-complete` moves the entry to `refs/merge-queue-done/`, which keeps the
pair (what was submitted, what it became) auditable afterwards — and, now that
the entry's own commits are not on the target branch, keeps those commits
reachable at all once the branch is deleted. Removing the worktree and branch is
yours to do, not the author's — they were told to leave them alone.

Three guards, each for something that has gone wrong before:

- **`[ -z "$wt" ]`** — the author may have removed their own worktree already,
  and `git worktree remove ""` fails with `fatal: '' is not a working tree`.
- **the tip comparison** — if the branch moved *again* while you were merging,
  deleting it would destroy those commits. Keep it, and say so.
- **`-D`, not `-d`** — the rebase rewrote the commits and the squash replaced
  them, so `-d` refuses even when everything landed. That is exactly why the
  tip comparison has to do the safety check `-d` would otherwise have done for
  you.

Then back to **The VM tests**, above, for whatever is behind it.

## Reporting

Per wake-up, one short block:

```
queue: 3 entries
  20261013T1147  docs-testing    squashed to f00ba12, clean, VM tests not affected
  20261013T1152  modules-sonarr  squashed to 3c1d8ae, conflict in Makefile, note added, VM tests passed
  20261013T1159  hosts-manaan    BLOCKED: manaan-upgrade failed, rollback never ran
main now at 3c1d8ae; 1 entry still pending
```

Say for every entry landed whether the VM tests ran or were not affected.

Name every blocked entry and why, every conflict you resolved, and anything you
force-removed. Do not push, and do not tag — the target branch stays local
unless the user asks otherwise.

`make queue-log` is what you have drained, `make queue-notes` is every
resolution you have recorded, `make queue-history` is the branch's own log with
the entry behind each commit, and `make queue-show ENTRY=<entry>` reconstructs
one afterwards — the message it landed under, the commit it landed as, the
commits that were squashed into it, and where to find them now.
