# The Change Workflow

**Every change to this repository goes through this workflow — feature, fix,
refactor or documentation edit alike.** Invoke `/worktree-task`, which holds the
detail; what follows is the shape.

```
  worktree  →  iterate on the prompt  →  do the work  →  message  →  submit
   (first)        (before editing)        (commits)      (last)     (queue)
                                                                        │
                                       /merge-queue, in its own session │
                                       squashes it on, in order       ◄─┘
```

The queue is `queue/queue.sh`, driven by the `queue-*` targets in
`queue/queue.mk`; `make queue-help` lists them. **Run them from the repository
root or a worktree root** — `make` does not search upward for a Makefile, and
`queue-submit`, `queue-worktree` and `queue-handover` act on the branch checked
out where you are standing. Merge messages go through the **environment**, not
a make variable: `M="..." make queue-submit`, because make mangles the
backticks, `$` and `#` a real message contains.

## 1. A worktree, before anything else

```bash
make queue-worktree BRANCH=<branch-name>    # prints .worktrees/<id>
cd .worktrees/<id>
```

Create it **before inspecting or modifying any repository file** as part of the
task, and do every read, edit, commit and test run from inside it.

The worktree is named with a **queue id** — `20261013T094402.118293` — which
`queue-worktree` claims up front and which `queue-submit` then reuses, so the
directory and the queue entry share one name. Do not invent the directory name:
a name chosen by whoever is about to do the work can be chosen identically by a
second agent working at the same time, and an id cannot collide. The **branch**
keeps a descriptive name, because that is what `make queue-list`,
`queue-status`, `queue-show` and `queue-diff` are addressed by.

- All worktrees live under `.worktrees/` at the repository root. It is
  git-ignored and must never be committed.
- One worktree per independent piece of work.
- Branch from the target branch, unless the work needs what another branch has
  not finished — then branch from that branch's **handover point**, below. A
  branch that predates the queue's installation cannot reach the tooling: it
  has no `queue/queue.mk` in it, and the symptom is `make: *** No rule to make
  target 'queue-submit'`. A long-lived branch must rebase before it can be
  submitted.
- **Never modify the main checkout.** It is the merge queue's target; a dirty
  main checkout blocks the queue.
- Use the task's own branch, never the target branch directly.

Not `.git/worktrees/` — git owns that path for its own per-worktree admin files
(`HEAD`, `index`, `gitdir`, `logs/`), and a checkout placed there shares a
directory with them: `git status` lists them as untracked forever, `git add -A`
stages them, `git clean -fd` deletes them, and `git worktree remove` refuses
without `--force`.

### Starting from work that has not landed

Work that needs what another branch has half-finished starts from a **handover
point** on that branch: an annotated tag at a commit, whose message says what
is finished there.

```bash
M="the client-minted identity is done and tested.
The per-session directories are NOT -- api/edit.go is still a stub." make queue-handover
# handover  handover/api-identity/1  at 7e90326

make queue-worktree BRANCH=api-edit-dirs FROM=handover/api-identity/1
```

A sha cannot do this job. The drain squashes a branch into one commit and
deletes the branch, so a sha quoted in a handover document names nothing a
reader can reach, and the document is reduced to telling the next agent to
inspect the queue and work out for itself whether that work has landed yet. The
tag survives both, so it is the reference a handover document gives:
`FROM=handover/<branch>/<n>` is the same branch point next week as today.

**Write the point before the document, and quote the point in it.** What the
next agent needs is one unchanging branch point plus a sentence about what is
finished at it, which is exactly what the tag is.

Then:

- The entry submits only **its own** commits, never the parent's, because the
  branch point was recorded before the work started.
- It cannot land before the work below the point does. The queue orders it
  behind that entry automatically; `queue-submit` refuses while that work has
  not been submitted at all, since the queue can only order what is in it.
- `make queue-handovers` says where the work below each point stands — in
  progress, pending, landed as `<sha>`, or withdrawn. The squash means ancestry
  cannot answer that, so the queue answers it: locally from its own refs, and
  on a clone from the `Queue:` trailer on the landed commit.
- `make queue-handover POINT=<point>` adds what is complete below it, what the
  branch added after it, and who else has started from it.

## 2. Iterate on the prompt before writing code

Turn the request into a statement of what will change and why, in the
repository's own vocabulary — its glossary, if it has one — and get agreement
on that statement before editing. Name the ambiguities and which reading you
are taking; say what you will not do; surface the decision record, test or
neighbour that constrains the change. If the repository has a design-review
skill, it stress-tests a design; a domain-modelling one captures the vocabulary
and decisions it turns up.

## 3. Commit in the git subsystem format

```
<subsystem>: <summary, lower case, no trailing period>

<body: why this change, wrapped at 72 columns>
```

The subsystem is a place in this repository, named as deeply as the change is
specific — `api`, `web`, `docs`, `queue`, `build`, whatever this repository's
own top-level divisions are:

```
api: bind the inspect listener before reading any files
web: fetch the upload limit from config, not the bundle
```

**Not conventional commits.** No `feat:`, `fix:`, `chore:`, no `type(scope):`,
no `!`. The body explains *why*, including what the change costs and what is
still broken and in the way. This is the documented default; a repository with
its own commit convention substitutes it here, and nothing else changes — the
queue cares only that the message exists and says what the change does.

The `Queue:` trailer that names the entry is appended by the drain — never
write it by hand. (A repository using Gerrit will have a `commit-msg` hook that
appends a `Change-Id`; that is the hook's job, not yours either.)

## 4. The merge message, written last

The branch lands as a single squashed commit, and its message is the one thing
the target branch says about the change. There is no `CHANGELOG.md`: `git log`
is the changelog, one commit per change. Write the message after the work is
finished and hand it to the submission rather than committing it:

```bash
M="<subsystem>: <short subject>

<one short sentence saying what the change does>" make queue-submit
```

A short subsystem-prefixed subject, a blank line, then a body that is an
**overview of what the change does** — not documentation of how it works, which
is in the diff, and not the reasoning, which is in the branch's own commits.
One short sentence unless more is asked for; direct and causal; in the asker's
wording where it fits; preferring the pattern "`X` only does `Y`, so it also
needs `Z` for `W`"; no caveats that are not essential.

`make queue-message ENTRY=<entry>` prints the recorded message and
`M="..." make queue-message ENTRY=<entry>` rewrites it, which is what to do
when work continues after submitting and the message stops describing the
entry.

## 5. Submit to the merge queue

```bash
M="..." make queue-submit    # from the worktree root, everything committed
```

Submission does not merge anything: it records the branch as
`refs/merge-queue/<id>/<branch>` and returns. **Do not merge your own work, do
not push, and do not delete your worktree** — the draining agent does that once
the entry has actually landed.

Submitting is not a freeze either. The drain merges the branch as it stands
when it gets there, so a fix committed after submitting still lands; write it
as an ordinary commit and leave the entry alone.

Nothing starts the draining agent for you. An unattended queue simply grows,
with no nag and no notification — `make queue-status` is how you find out.

```bash
make queue-worktree BRANCH=<branch>            # start work: a worktree named with a queue id
make queue-worktree BRANCH=<b> FROM=<point>    # ...starting from unlanded work
M="..." make queue-handover                    # mark where you are as a point others may start from
make queue-handovers                           # every point, and whether the work under it landed
make queue-handover POINT=<point>              # one point in full
make queue-status                              # where the branch is, what is waiting, what is stuck
make queue-check                               # replay the queue to find conflicts early
make queue-drain                               # land the queue, in order, up to the first conflict
make queue-list                                # the pending queue, in merge order
make queue-show ENTRY=<branch>                 # one entry in full, by branch name, id or prefix
make queue-diff ENTRY=<branch>                 # what an entry would bring; ARGS=--stat
make queue-message ENTRY=<branch>              # what the log will say about it
make queue-notes                               # every conflict resolution recorded so far
make queue-log                                 # what has been merged or withdrawn
make queue-sessions ENTRY=<branch|commit>      # the session transcripts that worked on it
make queue-drop ENTRY=<branch>                 # withdraw an entry; branch and worktree untouched
make queue-merge                               # land the head of the queue, if it is clean
make queue-merge ENTRY=<branch>                # ...or a named entry, out of order if need be
make queue-help                                # every queue target
make queue ARGS="show <branch> --stat"         # queue.sh directly, for anything the above cannot say
```

Entries are identified by a UTC timestamp — `20261013T094402.118293` — which
orders them without having to allocate a number, and so without two concurrent
submissions ever colliding on one. Anywhere an id is wanted, a branch name or
an unambiguous prefix of the id will do. It is also the name of the worktree
the work was done in, since `queue-worktree` claimed it before the work rather
than at submission; a worktree made by hand has no id in its name, and
`queue-submit` claims one for it at submission.

`queue-check` runs the drain's own rebase, in order, in a scratch worktree it
removes afterwards, touching neither the target branch nor any entry — so a
conflict it reports is the conflict the draining agent will meet. That worktree
is named per run, so two agents checking at the same time do not collide; a
check killed outright leaves one behind, which the next check reports and
leaves alone.

`queue-merge` is that drain's clean path for a single entry, without the agent:
it takes the same lock, replays the entry, squashes it under the author's
message, fast-forwards the target branch and clears up the branch and worktree
— and refuses the moment anything needs deciding. A conflict stops it with the
branch untouched and the entry still pending, because resolving one is a
judgement about someone else's code that has to be recorded as a note, which is
`/merge-queue`'s job and not a shell script's. It defaults to the head of the
queue; named, it will merge an entry out of order, but never one that is
orphaned or stacked on an entry that has not landed.

## 6. A dedicated agent merges the queue

`/merge-queue`, run in its own session in the main checkout — usually
`/loop /merge-queue` — is the only thing that writes to the target branch. It
merges entries **in submission order**, one at a time: each entry's commits are
replayed on, then squashed into **one commit** under the message its author
submitted, with one trailer appended naming the entry it came from:

```
Queue: 20261013T114729.172739 api-named-queries 7e90326
```

History stays linear, queue order reads as commit order, and the branch reads as
one commit per change rather than one per step. The entry's own commits are not
on it; after the branch is deleted they are reachable only through
`refs/merge-queue-done/<id>/<branch>`.

The trailer is what makes the branch itself say which commits came through the
queue, and which entry each one was — `make queue-history` prints it, and
`make queue-show ENTRY=<entry>` follows the same link the other way.

The id and the branch are the key to every other namespace, so that pair
recovers the base, the message and the squashed commits; the submitted sha is
carried literally because the rebase rewrote it and the squash left it off the
target branch. A merge commit per entry was considered instead and measured:
the drain rebases onto the branch's tip first, so the merge would be degenerate
— every entry twice in `git log --oneline` under one subject, an empty patch
from `git show`, and the pair printed out of topological order when both land in
the same second — while `git log -- <path>`, `git log -S` and `git blame` would
all still resolve to the squash.

`make queue-drain` is that merge, minus the judgement: it lands every entry it
can, in order, and stops at the first one that needs a decision rather than
making it. The replay is the conflict test — it happens in the scratch worktree
and the target branch is only written by the fast-forward afterwards — so an
entry it will not merge leaves the branch exactly as it was. What it stops on is
the agent's work: the agent resolves, records the note, and runs `drain` again.

Conflicts are resolved by that agent, never by `drain`, and **every resolution
is recorded as a git note** on the resulting commit: what the two sides did,
what was kept, and why. `git log` shows those notes with no extra flags. An
entry it cannot land blocks the queue rather than being skipped, because what
follows it was written against what precedes it.

`.worktrees/.merge-queue` is that agent's scratch worktree and also its lock:
it exists for the length of a drain, a second drain cannot create it, and
`make queue-drop` refuses while it is there. Finding it when no drain is
running means one died — inspect it before removing it, since it may hold a
half-finished rebase.

`/branch-review`, also in its own session in the main checkout and usually
under `/loop /branch-review`, is the optional review between submitting and
landing. Each run takes the next entry whose tip has no `Reviewed:` trailer,
fixes only what would be wrong on the target branch, and stamps the tip with
`Reviewed: <id>` from `make queue-id`. It never touches the entry, so a branch
that moves after submission because of it is a review, not a surprise — and
a commit made after a review leaves a tip with no stamp, which is the next
run's work.

The queue and the git notes are both **local to this machine**: neither is
pushed. A fresh clone therefore starts with an empty queue and no record of any
past conflict resolution. The `Queue:` trailer is the exception, because it is
on the commit rather than beside it — on a clone it is the whole of the
provenance, which is why the submitted sha is written into it rather than left
to the refs.
