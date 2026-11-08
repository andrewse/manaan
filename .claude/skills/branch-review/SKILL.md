---
name: branch-review
description: Review a branch waiting in the merge queue before it lands — take the next unreviewed entry, review the commits nobody has reviewed yet against the message the entry will land under, change only what would be wrong on the target branch, and stamp the branch tip with a `Reviewed:` trailer. One entry per run, usually under /loop. Use when asked to review the merge queue, a queued branch, or submitted work that has not landed.
---

# Reviewing a branch waiting in the queue

An entry sits in the merge queue between "the author stopped" and "the drain
squashes it onto the target branch" (`main`, unless this repository set
`QUEUE_MAIN`). This is the review that happens in that gap, while the work is
still a branch and a fix is still an ordinary commit — rather than after it has
landed, when the same fix is a second commit on the target branch apologising
for the first.

```
submit  →  branch-review  →  /merge-queue  →  target branch
            (this skill)       (the drain)
```

The queue is `queue/queue.sh`, driven by the `queue-*` targets in
`queue/queue.mk`; `make queue-help` lists them. **Run them from the repository
root** — the queue is read from the main checkout, which is where the Makefile
is, and `make` does not search upward for one.

You review one entry and the run is over. A loop starts the next run, which
takes the next unreviewed entry; nothing here walks the whole queue in one go,
because a review that spans seven branches is one report nobody acts on and
seven branches left half-read when the context runs out.

```
/loop /branch-review
```

Run it in the **main checkout**, in its own session — not in a worktree that
is somebody's work. You read the queue from there and do the reviewing inside
the entry's own worktree, which is the only checkout its branch has.

The thing a run leaves behind is a trailer on the branch tip:

```
Reviewed: 20261019T101741.655390
```

A fresh id from `make queue-id` — the queue's own timestamp format, so when a
branch was last reviewed compares directly against the ids of the entries
around it. It records that the branch **was reviewed**, not that it was
approved: what the review concluded is in the report, and in a git note when
there was something it could not fix.

That trailer is also how the next run knows where to start. The tip carries it,
so an author who commits again after a review leaves a tip that does not —
which is exactly right, because there is new work nobody has looked at.
"Unreviewed" therefore means **the tip has no `Reviewed:` trailer**, and it is
true again every time the branch moves.

## The invariants

1. **One entry per run.** Review it, stamp it, report, stop.
2. **Order is a preference, not a rule.** Take the first unreviewed entry in
   merge order, but reviewing entry 5 before entry 3 breaks nothing: a review
   does not touch the target branch and does not reorder the queue. This is the
   one place the queue's discipline is looser than `/merge-queue`'s, where
   order is absolute.
3. **Only what would be wrong on the target branch.** You are editing someone
   else's branch under their name. The bar is not "I would have written it
   differently", it is "the branch is wrong if this lands". Everything below
   that bar is reported, not changed.
4. **You do not change what the entry is for.** A missing feature, a better
   design, an adjacent thing that needs doing — say so in the report. The user
   decides whether it is work. A review that grows the change is no longer a
   review of it.
5. **Every finished review stamps the tip.** Including one that found something
   it could not fix — otherwise the next run picks the same entry up again
   forever, and the loop never reaches entry 2. The stamp means looked at; the
   note and the report say what was found.
6. **You never touch the queue entry.** No `queue-submit`, no `queue-drop`, no
   `queue-merge`, no `queue-message`. If your fix changed the shape of the
   change enough that the merge message is now wrong, report that — rewriting
   it would put your description of someone else's change on the target branch.
7. **You never rebase, force-push, or delete anything.** Not the branch, not
   the worktree, not a commit. The branch tip moves forward by your commits or
   by one amended message, and that is all.
8. **Never edit the main checkout.** It is the queue's merge target, and a
   dirty main checkout blocks the drain.

## 1. Take the lock, then pick the entry

```bash
git worktree add --detach .worktrees/.branch-review main
```

That is the lock, and the reason it is a worktree rather than a directory is
step 2: an entry whose author already removed their worktree has no checkout,
and this one can be switched onto the branch to become it.

If the path already exists, stop: another review is running, or an interrupted
one left it behind. Do not force past it — two reviews on one branch means two
agents amending the same tip.

Then read the queue and find the first entry whose tip is unstamped:

```bash
make queue-list
make -s queue-list | tail -n +2 | awk '{print $1"\t"$2}' |
    while IFS=$'\t' read -r id branch; do
        [ -n "$(git log -1 --format='%(trailers:key=Reviewed,valueonly)' "$branch")" ] ||
            { printf '%s\t%s\n' "$id" "$branch"; break; }
    done
```

Nothing out of that — an empty queue, or every tip stamped — and the run is a
no-op. Report it as one and sleep. That is the normal finding on a quiet queue,
not a problem.

With a candidate, read it and check it is in a fit state to review:

```bash
make queue-show ENTRY="$id"   # branch, worktree, the commits submitted, the files
wt=...                        # the worktree path show printed
git -C "$wt" status --porcelain
```

- **Dirty worktree** — somebody is working in there, or left something behind.
  Skip the entry, name it in the report, and take the next unreviewed one.
  Reviewing a tree in flux reviews a state that will not exist, and amending a
  tip under a live session moves `HEAD` beneath it.
- **No worktree** (the path is empty or gone) — the author removed it. Switch
  the lock worktree onto the branch and work there:
  `git -C .worktrees/.branch-review switch "$branch"`, remembering that step 7
  has to switch it back off the branch before removing it. If the branch is in
  fact still checked out somewhere, git refuses and names the path — believe
  it, and treat the entry as the dirty case above.
- **Orphaned or waiting** (`make queue-status` names both) — the entry is
  stacked on work that will never land, or has not landed yet. It is still
  worth reviewing on its own terms; say in the report that the entry is blocked
  for a reason that is not yours, and do not try to fix the stacking.

One race you cannot lock out: `/merge-queue` takes the branch as it stands when
it gets there, so a drain running in another session can land and delete the
entry you are reviewing. If the branch or worktree disappears under you, that
is what happened — stop, say so, and let the next run take the next entry. It
is also an argument for reviewing the queue rather than its head: the entries a
drain is about to reach are the ones a review has least time to help.

## 2. Work out what has not been reviewed

Two things to read before any judgement:

```bash
make queue-message ENTRY="$id"   # what the target branch will say this change does
make queue-diff ENTRY="$id"      # everything the entry would bring to it
```

The message is the specification you review against. An entry whose diff does
something the message does not mention is a finding in itself — either the
change grew or the message is wrong, and which of the two it is decides whether
anything needs fixing.

Then the range. `make queue-show` lists the entry's own commits, oldest first:

```bash
last=$(git -C "$wt" rev-list -1 --grep='^Reviewed: ' HEAD)
```

- **`last` is empty, or is below the entry's own commits** — nothing in this
  entry has been reviewed. A stamp below the oldest commit `queue-show` listed
  belongs to the work this entry was *started from*, and reviewing that is not
  this entry's business. Review the whole of `make queue-diff ENTRY="$id"`.
- **`last` is one of the entry's commits** — review only what arrived since:

  ```bash
  git -C "$wt" log "$last"..HEAD
  git -C "$wt" diff "$last"..HEAD
  ```

  This is the ordinary case under a loop. A branch gets reviewed, the author
  commits two more things, and the next run reads those two commits against a
  branch it has already read once. Read the earlier commits for context when
  the new ones only make sense against them; do not re-report what the last
  review already decided.

## 3. Review it

Read the new commits as commits — each one's message against what it does —
and then the range as a whole against the merge message. Run the checks the
part of the repository you are reviewing actually has — its test command, its
linter, its build — **before** you change anything, so you know what the entry
arrived with. Here that is `make test-unit test-integration`, and for a change
to the queue itself, `make queue-selftest` too. Not the system tests (`make
test-system`, `test-system-all`, `check`): they are too expensive to run more
than once, so the merge queue runs them, once, after a drain.

A failure that was already there is a finding about the entry. A failure you
introduce while fixing something is yours, and step 4 does not finish until it
is gone.

What counts as critical — the bar from invariant 3, which is "the target branch
is wrong if this lands":

- it is **wrong**: the logic does not do what the message says, an error is
  swallowed, a boundary is off, a nil or an empty case reaches code that cannot
  take one;
- it **loses or corrupts** something: data, a file, a ref, somebody's work;
- it **breaks an invariant this repository wrote down**: a decision record the
  change contradicts, a rule in the `AGENTS.md` of the directory it touches, a
  contract in the documentation of the part it changes. Read the AGENTS.md of
  every directory the diff touches — that is where the rule you are about to
  let through lives;
- it is **unsafe**: a credential, a token or a path out of a sandbox, in a diff
  that was not about any of those;
- the **tests pass for the wrong reason**: a test asserting the bug, a test
  that cannot fail, a suite the change quietly stopped running.

What is not critical, however much it reads like it: naming, structure, a
clearer way to write the same thing, a missing test for something that works, a
comment that could say more, a `TODO` left in. Report those in one line each
and leave the code alone.

Judge by intent, as a conflict resolution is judged: read what the author was
trying to do from the commit messages before concluding that a line is wrong.
Most of what looks critical at first reading is a thing you have not understood
yet, and a confident fix to one of those is worse than no review.

## 4. Make the critical changes

In the worktree, on the branch, as ordinary commits in the repository's format
— one coherent step each, `<subsystem>: <summary>`, body saying **why**.
`/worktree-task` phase 3 has the full rules; they are the same here, with one
addition: the body says the review found it, so whoever reads
`refs/merge-queue-done/<id>/<branch>` later can tell the author's commits from
the reviewer's.

```
api: answer the resume on the pool, not only on the three Store methods

branch-review of 20261019T093426.710407: the read paths took the pool
directly, so a waking database answered them with a 500 rather than the
503 the message says every verb now answers. Moved the wait to the pool.
```

Then re-run the checks, and do not stop until they pass. Nothing else goes in
these commits: no drive-by tidying, no renames, no reformatting of lines you
did not have to touch — the author has to be able to read your commit as a
statement about one thing.

If the fix needs a decision that is not yours — the entry is wrong in a way
with two defensible answers, or correcting it would change what the change is
for — **do not guess**. Leave the code alone, go to step 6, and say what the
decision is.

## 5. Stamp the tip

```bash
stamp=$(make -s queue-id)
git -C "$wt" commit --amend --no-edit --trailer "Reviewed: $stamp"
```

The same command whether or not you made fix commits. **If you did**, the
trailer goes on the last of them — your own commit, so amending it is free.
**If you changed nothing**, the tip is the author's commit and the amend adds
one trailer line to its message and nothing else.

`--amend` keeps the author and makes you the committer, which is the record of
who stamped it, and `--no-edit` means the message is untouched but for the
trailer git appends. Do not write the trailer by hand into a message, and do
not make an empty commit to carry it: an empty step in the entry's history is a
thing the drain has to squash and a reader has to wonder about.

Check it landed where you think:

```bash
git -C "$wt" log -1 --format='%H%n%an%n%(trailers:key=Reviewed)'
```

The tip has now moved, and that is expected and safe: `queue-submit` pinned a
sha but the drain merges the branch **as it stands when it gets there**, so the
stamp and the fixes land with the entry. `make queue-status` will report the
branch as moved since submission — say so in your report, so the draining agent
reads it as a review rather than as a surprise.

## 6. When there was something you could not fix

A note on the commit you stamped, so the finding travels with the code instead
of only with your report:

```bash
git -C "$wt" notes add -m "$(cat <<'EOF'
branch-review: 20261019T093426.710407 api-waking-read-paths
reviewed: 20261019T101741.655390

Critical, not fixed: api/review/rest.go
  The read paths answer 503 with a Retry-After taken from the pool's own
  backoff, but PROTOCOL.md says the header is the database's estimate of
  when it will be awake. Those are different numbers and the document
  does not say which wins.
  Needs the author: which of the two the protocol means.

Not critical, reported only:
  waking_test.go duplicates the fixture in store/waking_test.go.
EOF
)" HEAD
```

The header names the entry and the stamp, then one block per finding, each
saying **what is wrong**, **why it is critical** and **what decision it
needs**. "Looks wrong, please check" is not a note.

Know what the note does not reach: `make queue-notes` reads notes on the
**target branch's** commits, and these commits never get there — the drain
squashes them. After the entry lands, the note is still reachable at
`refs/merge-queue-done/<id>/<branch>`, but the target branch itself will not
show it. So the note is for the author and for whoever digs the branch up
later; the live report below is what gets the finding acted on.

## 7. Finish the run

```bash
# if you borrowed the lock worktree as the branch's checkout, let the branch go
git -C .worktrees/.branch-review switch --detach main
git worktree remove --force .worktrees/.branch-review
```

Leave the entry's own worktree and branch exactly where they are: removing them
is the draining agent's job, after the work has actually landed.

Then report, and stop. The run is over whether the review was clean, fixed
something, or found something it could not fix — the next entry is the next
run's.

## Reporting

One block per run:

```
reviewed 20261019T093426.710407  api-waking-read-paths  (3 new commits)
  fixed    the read paths took the pool directly, so a waking database
           answered 500 where the message promises 503 -- 1 commit, tests pass
  BLOCKED  Retry-After's meaning contradicts PROTOCOL.md; needs the
           author to say which number wins. Note added.
  noted    waking_test.go duplicates a fixture (not changed)
  stamped  Reviewed: 20261019T101741.655390 -- tip moved, 665b982 -> 4a1c09e
skipped  20261019T093415.498845 web-upload-limits: worktree dirty
6 entries unreviewed behind this one
```

Say which entry, what you changed and why, what you did not change, what needs
the author, and that the tip moved. Name every entry you skipped and the reason
— a skip that goes unreported looks exactly like an entry that was reviewed and
found clean.

Do not merge, do not push, and do not tag. The branch stays a branch; landing
it is `/merge-queue`'s.
