---
name: worktree-task
description: The workflow for every change to this repository — a dedicated worktree, iterating on the prompt before writing code, subsystem-prefixed commits, the merge message written last, then submission to the merge queue. Use before touching any file in this repo, whether the request is a feature, a fix, a refactor or a documentation edit.
---

# Working on a change in this repository

Five phases, in order. The order is the point: the worktree exists before the
first file is read, the prompt is settled before the first file is written, and
the message the target branch will carry is written after the work is done
rather than alongside it.

```
  worktree  →  iterate on the prompt  →  do the work  →  message  →  submit
   (first)        (before editing)        (commits)      (last)     (queue)
```

The queue is `queue/queue.sh`, driven by the `queue-*` targets in
`queue/queue.mk`; `make queue-help` lists them. **Run them from the repository
root or a worktree root** — `make` does not search upward for a Makefile, and
`queue-submit`, `queue-worktree` and `queue-handover` all act on the branch
checked out where you are standing. If `bin/q` was installed, `q submit -m
"..."` works from any subdirectory.

Merge messages go through the **environment**, not a make variable:
`M="..." make queue-submit`. They are multi-line and contain backticks, `$` and
sometimes `#`, all of which make mangles in a command-line assignment.

Nothing here merges anything. Submitting hands the branch to a queue that a
separate agent drains; see `.claude/skills/merge-queue/SKILL.md`.

## 1. The worktree, before anything else

```bash
make queue-worktree BRANCH=queue-drop-guard
# worktree  /path/to/repo/.worktrees/20261013T094402.118293
# branch    queue-drop-guard (from main, 6312433)
# id        20261013T094402.118293 -- the name of the worktree, and the id submit will use
cd .worktrees/20261013T094402.118293
```

Create it **before inspecting or modifying any repository file** as part of the
task, and do every read, edit, commit and test run from inside it.

Branch from the target branch — unless the work needs what another branch has
not finished yet, which is **Starting from work that has not landed**, below.

A worktree on a branch that predates the queue's installation cannot reach the
tooling: the branch has no `queue/queue.mk` in it, and the symptom is
`make: *** No rule to make target 'queue-submit'`. A long-lived branch must
rebase onto the target branch before it can be submitted.

- `.worktrees/` is git-ignored and must never be committed.
- One worktree per independent piece of work. Two unrelated changes are two
  worktrees, not one branch with two subjects.
- Never edit the main checkout. It is the queue's merge target; a dirty main
  checkout blocks the draining agent.
- **Do not name the directory yourself.** `queue-worktree` claims a queue id
  and names it after that, and `queue-submit` reuses the id its worktree
  carries, so the directory and the queue entry are one name. A name you
  invent, another agent working at the same time can invent too — and then one
  of you is editing the other's checkout. An id is a microsecond timestamp
  taken under git's must-not-exist lock and cannot collide.
- **The branch name is yours to choose**, and reads as the subsystem plus the
  change: `api-named-queries`, `web-upload-limits`, `queue-drop-guard`. It is
  what `make queue-list`, `queue-status`, `queue-show` and `queue-diff` are
  addressed by, which is why it stays a name and not a timestamp.

`git worktree add .worktrees/<name> -b <name>` by hand still works, and
`queue-submit` claims an id at submission for a worktree whose name does not
carry one — but then nothing stops two agents picking the same `<name>`, which
is the whole reason not to.

`.worktrees/` was chosen over `.git/worktrees/`, which git already owns: a
checkout placed there shares a directory with git's own per-worktree admin
files (`HEAD`, `index`, `gitdir`, `logs/`), so `git status` lists them as
untracked forever, `git add -A` stages them, `git clean -fd` deletes them, and
`git worktree remove` refuses without `--force`.

### Starting from work that has not landed

Sometimes the work needs what another branch has half-finished. Start from a
**handover point** on that branch rather than from the target branch:

```bash
make queue-handovers                      # the points that exist, and whether each has landed
make queue-handover POINT=api-identity/1  # one in full: what is complete below it

make queue-worktree BRANCH=api-edit-dirs FROM=handover/api-identity/1
```

The entry then submits only **its own** commits, and the queue orders it behind
the entry it was started from. `queue-submit` refuses while that work has not
been submitted at all — the queue can only order what is in it — so if you hit
that, ask the session that owns the branch to submit; submitting is not a
freeze and it can keep committing afterwards.

`FROM=` also takes a branch, an entry or any commit. Without a handover point
on it, nothing records whose work the branch point belongs to: the queue cannot
then tell you when that work has landed, and a withdrawal will not warn that it
orphaned you. `queue-worktree` says so when that happens.

## 2. Iterate on the prompt before writing code

The first request is rarely the specification. Before editing, turn it into a
statement of what will change and why, and get agreement on that statement.

- Restate the request as the change you are about to make, in the repository's
  own vocabulary — use the repo's glossary, if it has one. If the right word
  does not exist yet, that is a finding.
- Name what is genuinely ambiguous, and say which reading you will take. Ask
  only where two readings produce materially different work.
- Say what you will *not* do, so the boundary is explicit.
- Surface the constraints you found while looking: a decision record that
  already settled this, a test that pins the current behaviour, an adjacent
  thing that will break.
- Then propose the approach and confirm it.

If the repository has a design-review skill, reach for it when the design
deserves to be stress-tested, and for a domain-modelling one when the iteration
turns up new vocabulary or a decision worth recording.

Loop until the prompt is sharp. Only then write code.

## 3. Do the work, committing in the git subsystem format

```
<subsystem>: <summary, lower case, no trailing period>

<body: why this change, wrapped at 72 columns>
```

The subsystem is the part of the repository the change belongs to, as the
directory layout names it, and as deeply as the change is specific: `api`,
`web`, `docs`, `queue`, `build` — whatever this repository's own top-level
divisions are. A change spanning several picks the primary one rather than
listing them.

```
api: bind the inspect listener before reading any files
web: fetch the upload limit from config, not the bundle
queue: refuse a submission whose worktree is dirty
```

This is the documented default. A repository with its own commit convention
substitutes it here, and the rest of this skill is unaffected — the queue cares
only that the message exists and says what the change does.

Rules:

- **Not conventional commits.** No `feat:`, `fix:`, `chore:`, no
  `type(scope):`, no `!` breaking marker. The subsystem is a place in this
  repository, not a change category.
- Lower case after the colon, no trailing period, subject short enough to read
  in a log — around 50 characters, 72 at the outside.
- The body explains **why**, not what. The diff already says what. Write what
  the old behaviour cost, what else was considered, what the change costs, and
  what is still broken and in the way — a commit that names the thing it did
  not fix is worth far more later than one that implies everything is fine.
- Several commits per task is normal and good: one coherent step each.
- Do not write a `Queue:` trailer by hand. The drain appends one to the commit
  it puts on the target branch, naming the entry it came from; it belongs to
  the queue and not to you. (A repository using Gerrit will have a `commit-msg`
  hook that appends a `Change-Id` — that is the hook's job, not yours either.)

These commits are the working record, and the target branch does not keep them:
the queue squashes the entry into a single commit under the message from phase
4. They stay reachable through `refs/merge-queue-done/<id>/<branch>` after the
branch is deleted, so keep writing them for whoever goes looking there — and
put what a reader of the target branch needs into the merge message rather than
here.

Run the checks that the part of the repository you touched actually has — its
test command, its linter, its build — and say plainly in the commit if
something fails and you are leaving it failing. Here that is always `make
test-unit test-integration`, which take seconds; the queue runs them again on
the tree the entry will land as, and will not land it while they fail. For a
change to the queue itself, add `make queue-selftest`.

A change in behaviour comes with its tests, in the category it belongs to (see
"Testing" in README.md): a unit test beside the script or module it covers, an
integration test under `tests/integration/` for scripts or modules working
together.

**Not the system tests.** `make test-system`, `test-system-all` and `check`
install, boot and upgrade every host in QEMU, about ten minutes per host on
this Mac plus rebuilding its image. The merge queue runs them once, after a
drain, on everything that landed — see **The tests** in
`.claude/skills/merge-queue/SKILL.md`. Running them here as well spends that
on a tree that is not the one that lands.

## 4. The merge message, written last

The branch lands as **one commit**, squashed, and this is its message — the
only thing the target branch will ever say about the change. There is no
`CHANGELOG.md`: `git log` is the changelog, one commit per change.

Write it once the work is finished, because only then is the change's shape
known, and hand it to the queue with the submission:

```bash
M="queue: squash each merged entry into one commit

Changed the merge queue to use squash commits, to keep the history single
commits with PR-like descriptions." make queue-submit
```

The shape is the repository's commit format: a short `<subsystem>:` subject,
exactly as phase 3 writes one, a blank line, then a body. The drain appends a
`Queue:` trailer naming the entry, which is the one line of this that is not
yours to write. `queue-submit` warns if the subject runs past 72 columns or if
line 2 is not blank, and takes it anyway — the shape is a convention worth
holding to, not one worth blocking finished work over.

**The body is an overview of what the change does** — not documentation of how
it works. Someone reading the log wants the change; the mechanism is in the
diff and the reasoning is in the squashed commits. Six rules for it:

1. Use one short sentence unless more is asked for.
2. Be direct and causal.
3. Preserve the user's wording where possible.
4. Prefer the pattern: "`X` only does `Y`, so it also needs `Z` for `W`."
5. Avoid caveats unless they are essential.
6. Do not explain the reasoning after the sentence unless asked.

So, for the change that made `submit` refuse a dirty worktree:

```
queue: refuse a submission whose worktree is dirty

`submit` only pins the branch, so it also needs to refuse a dirty worktree for
uncommitted work not to be left behind without anyone being told.
```

`make queue-message ENTRY=<entry>` prints what is recorded, and
`M="..." make queue-message ENTRY=<entry>` rewrites it while the entry is
pending.

## 5. Submit to the queue

From the root of the worktree, with everything committed:

```bash
M="<the merge message from phase 4>" make queue-submit
```

That records the branch as `refs/merge-queue/<id>/<branch>`, stores the message
at `refs/merge-queue-msg/<id>/<branch>`, and returns. It refuses a dirty
worktree, a branch with nothing the target branch does not have, a branch
already queued, and a submission with no message — an entry with no message has
nothing for its squash commit to say.

**Submitting is not a freeze.** The drain merges the branch as it stands when
it gets there, not as it stood when you submitted, so a fix committed
afterwards still lands. Write it as an ordinary commit and leave the entry
alone; `make queue-check` will show the branch has moved.

Then report to the user: what changed, the branch, the queue position, and
anything you are knowingly leaving behind. **Do not merge it yourself**, do not
`git push`, and do not delete the worktree — the draining agent removes it once
the entry has actually landed.

Nothing starts that agent for you. If no `/loop /merge-queue` session is
running, the queue simply grows; `make queue-status` is how you find out.

### When work continues after the message

It will. A check fails, a review lands, something turns out to be wrong — and
now there are commits the message was not written against. That is normal and
does not need undoing. Re-read the message and ask only whether it still
describes what the entry does:

- **It does** — the usual answer, because a fix to work that has not landed yet
  changes nothing a reader of the target branch would see. Leave it alone.
- **It does not** — the work's shape changed, so the message has to follow it:

  ```bash
  M="<the message as it should now read>" make queue-message ENTRY=<entry>
  ```

The rule is that the message describes finished work, not that no commit may
follow it. It is the entry's description of itself right up until the drain
commits it.

### Handing the work over to another agent

When the next piece of work is someone else's — a handover document, a prompt
for a fresh session — what they need from you is a **branch point that does not
move**, not instructions for working one out.

Take the point first, then write the document around it:

```bash
M="the client-minted identity is done and tested.
The per-session directories are NOT -- api/edit.go is still a stub." make queue-handover
# handover  handover/api-identity/1  at 7e90326
#
#       make queue-worktree BRANCH=<branch> FROM=handover/api-identity/1
```

Put that `FROM=` line in the document, and say in the message what is finished
at the point and what is not. Do **not** write a sha into a handover document,
and do not write instructions to go and inspect the queue to find out whether
the work has landed: the drain squashes this branch into one commit and deletes
it, so the sha stops resolving for the reader and the queue question is the one
the point exists to answer. `make queue-handovers` answers it — in progress,
pending, landed as `<sha>`, or withdrawn — and the tag keeps the commit itself
readable for good, so `git log`, `git show` and `git diff` against it still work
after the branch is gone.

A point can be taken at any commit on your branch, not only the tip:
`AT=<commit>`. Take one wherever you stopped at something another agent can
build on.

### Checking your entry once it is in

Submitting is cheap and withdrawing is free, so the pre-flight happens *after*
submitting rather than before — once the entry is in the queue, `queue-check`
can replay it in its real position:

```bash
M="..." make queue-submit
make queue-check           # replay the queue; find conflicts early
```

`queue-check` does the same rebase the draining agent will do, in the same
order, cumulatively, in a scratch worktree it removes afterwards. It touches
neither the target branch nor your branch. A conflict reported there is the
conflict that agent will meet, so it is worth resolving the cause now — usually
by rebasing your branch yourself and resubmitting — rather than leaving it for
them to decide.

The rest of the inspection:

```bash
make queue-status                  # where the branch is, what is waiting, what is stuck
make queue-show ENTRY=<branch>     # one entry in full; takes an id or prefix too
make queue-message ENTRY=<branch>  # what the log will say about it
make queue-diff ENTRY=<branch>     # what it would bring; ARGS=--stat for a summary
make queue-list                    # where your entry sits in the order
make queue-notes                   # conflict resolutions recorded so far
make queue-drop ENTRY=<branch>     # withdraw it; branch and worktree untouched
make queue-handovers               # every handover point, and where its work stands
```

`queue-drop` refuses two things. While a drain is running, because withdrawing
an entry out from under it leaves the work landed and the log saying it was
withdrawn. And when another pending entry is **stacked** on yours — started
from your tip, or from a handover point on your branch — because dropping it
would orphan that entry: it would then replay onto a target branch that never
receives what it was written against, usually without a single conflict to warn
anyone. `FORCE_DROP=1` overrides the second one, after you have read what it
lists.
