# The merge queue -- how finished work reaches the target branch.
#
#   make queue-help               see every queue target
#
# This file is `include`d by the repository's own Makefile, so every target is
# namespaced `queue-` to avoid colliding with targets the repository already
# has: `test`, `check` and `install` are all likely collisions, `queue-test`
# and `queue-check` are not.
#
# Every submission carries a message, which is the one thing the target branch
# will say about the entry: the drain squashes the entry's commits into a
# single commit and gives it that message. There is no changelog to write
# instead -- the branch's log is it.
#
# To that message the drain appends one trailer naming the entry it came from:
#
#     Queue: 20261013T114729.172739 api-named-queries 7e90326
#
# so the log says which of its commits came through the queue, and which entry
# each one was -- which is what `make queue-history` prints.
#
# The id and the branch are the key to every other namespace, so that pair
# recovers the base, the message and the commits that were squashed; the
# submitted sha is carried literally because the rebase rewrote it and the
# squash left it off the branch. The trailer is also the only part of any of
# this that is ever pushed -- every refs/merge-queue* ref is local to the
# machine that merged -- so on a clone it is the whole of the provenance.
#
# Submitting does not merge anything, and does not freeze anything either: the
# drain merges the branch as it stands when it gets there, so a fix committed
# after submitting still lands. `queue-drain` does the landing: it squashes
# entries on in submission order and stops at the first one that needs a
# decision. Deciding is the part it leaves out -- a dedicated agent,
# `/merge-queue` in its own session and usually under `/loop`, runs the drain,
# resolves the conflict it stops on, records the resolution as a git note, and
# runs it again. See .claude/skills/merge-queue/SKILL.md.
#
# `queue-merge` is that drain's clean path, for one entry, without the agent:
# it lands an entry that replays without conflict and refuses the moment
# anything needs deciding. A conflict is still /merge-queue work, because
# resolving one is a judgement about someone else's code that has to be
# written down.
#
# Nothing starts that agent for you. An unattended queue simply grows; `make
# queue-status` is how you find out, and there is deliberately no nag.
#
# A HANDOVER POINT is how work starts from work that has not landed. A sha
# cannot serve: the drain squashes an entry's commits into one and deletes the
# branch, so a sha quoted in a handover document names nothing a reader can
# reach, and the document has to tell the next agent to inspect the queue and
# work out for itself whether that work has landed. An annotated tag survives
# both, and its message is where the author says what is finished at that
# point -- so `FROM=<tag>` is a branch point that does not move, and `make
# queue-handovers` answers "has the work under it landed" without anybody
# guessing.
#
# Entries are identified by a UTC timestamp. Anywhere one is wanted you may
# give the branch name instead, or any unambiguous prefix of the id.
#
# That id is also the name of the worktree the work was done in, because
# `queue-worktree` claims it before the work rather than at submission. A
# worktree name used to be invented by whoever was about to do the work, and
# two agents working at once can invent the same one; an id cannot collide.
#
# ---------------------------------------------------------------------------
# RUN THESE FROM THE REPOSITORY OR WORKTREE ROOT. `make` does not search
# upward for a Makefile the way `just` searches for a justfile, and
# `queue-submit`, `queue-worktree` and `queue-handover` all act on the branch
# checked out where you are standing -- so from a subdirectory they do not run
# at all, and from the wrong worktree they would act on the wrong branch.
# `bin/q`, if it was installed, walks up for you: `q submit -m "..."`.
# ---------------------------------------------------------------------------
#
# MESSAGES GO THROUGH THE ENVIRONMENT, not a make variable:
#
#     M="api: add the thing
#
#     Why it is there." make queue-submit
#
# Merge messages are multi-line and contain backticks, `$` and sometimes `#`,
# all of which make mangles in a command-line assignment -- `#` starts a
# comment and `$` starts an expansion. Passing it as an environment variable
# bypasses make's parser entirely, and the recipe reads "$M" straight from the
# shell. This is the single biggest ergonomic difference from the `just`
# interface this replaces.
#
# Everything else is an ordinary make variable: BRANCH=, ENTRY=, FROM=, AT=,
# POINT=, ARGS=.
#
# EXIT CODES SURVIVE, which the draining agent branches on: `queue-drain` and
# `queue-check` exit non-zero when they stop on something, and no recipe here
# swallows that with a `-` prefix or `|| true`. Make reports it as its own
# `make: *** [queue-drain] Error 1` on stderr and exits 2 -- the exact code is
# make's, not the script's, and there is no way to pass one through. Read the
# report the target printed, not the Error line: `landed 1, ... 1 still
# pending` with a CONFLICT above it is the drain working correctly.

# The directory this .mk file lives in -- NOT $(CURDIR), which is wherever
# make was invoked from, and not a literal `queue/`, which breaks if a target
# repository installs it elsewhere. Must be `:=` on this line: MAKEFILE_LIST
# grows as make reads further includes, so a deferred `=` would resolve to the
# wrong file.
QUEUE_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
QUEUE     := $(QUEUE_DIR)queue.sh

# The branch the queue merges into, for a repository whose trunk is not
# `main`. Set it in the including Makefile -- `QUEUE_MAIN := master`, before
# the include -- and it is exported from here, so queue.sh sees it however a
# target was invoked.
QUEUE_MAIN ?= main
export QUEUE_MAIN

## queue-help                       every queue target, and how to pass arguments
queue-help:
	@printf 'The merge queue. Run these from the repository or worktree root.\n\n'
	@grep -hE '^## ' $(MAKEFILE_LIST) | sed -e 's/^## /  /'
	@printf '\n  Merge messages go through the ENVIRONMENT, never a make variable:\n'
	@printf '      M="api: add the thing\n\n      Why it is there." make queue-submit\n'
	@printf '  make mangles backticks, $$ and # in a command-line assignment; the\n'
	@printf '  environment bypasses its parser. Everything else is a make variable.\n'
	@printf '\n  queue-handover does two things, on what you set: M=... takes a point\n'
	@printf '  here (AT=<commit> to mark another commit), POINT=<name> shows one in\n'
	@printf '  full. queue-handovers lists them all.\n'
	@printf '\n  ARGS= goes to git for queue-diff, queue-history and queue-log, to\n'
	@printf '  chaland for queue-audit, and\n'
	@printf '  `make queue ARGS="..."` runs queue.sh directly for anything this\n'
	@printf '  interface cannot express.\n'

# ---- working the queue ----------------------------------------------------

## queue-worktree BRANCH=<name>     start work: a worktree named with its queue id
##   ...FROM=<point>                 ...starting from a handover point or commit
queue-worktree:
	@$(QUEUE) worktree $(BRANCH) $(if $(FROM),--from $(FROM))

## M="..." queue-handover           mark where you are as a point others may start from
##   ...AT=<commit>                  ...marking that commit instead of HEAD
## queue-handover POINT=<name>      one point in full: what is finished below it
queue-handover:
	@if [ -n "$$M" ]; then \
	    $(QUEUE) handover $(if $(AT),--at $(AT)) -m "$$M"; \
	elif [ -n "$(POINT)" ]; then \
	    $(QUEUE) handover $(POINT); \
	else \
	    printf 'queue-handover: nothing to do. Set one of:\n\n' >&2; \
	    printf '    M="<what is finished here>" make queue-handover\n' >&2; \
	    printf '    make queue-handover POINT=<name>\n\n' >&2; \
	    printf 'make queue-handovers lists every point.\n' >&2; \
	    exit 2; \
	fi

## queue-handovers                  every handover point, and whether it has landed
queue-handovers:
	@$(QUEUE) handover

## M="..." queue-submit             submit the worktree you are standing in
##   ...BRANCH=<name>                ...or a branch by name
queue-submit:
	@$(QUEUE) submit $(BRANCH) -m "$$M"

## queue-message ENTRY=<entry>      what the target branch will say about that entry
##   M="..." queue-message ENTRY=..  rewrite it, while the entry is still pending
queue-message:
	@if [ -n "$$M" ]; then \
	    $(QUEUE) message $(ENTRY) -m "$$M"; \
	else \
	    $(QUEUE) message $(ENTRY); \
	fi

## queue-drop ENTRY=<entry>         withdraw an entry without merging it
queue-drop:
	@$(QUEUE) drop $(ENTRY)

# ---- landing it -----------------------------------------------------------

## queue-drain                      squash the whole queue on, in submission order
queue-drain:
	@$(QUEUE) drain

## queue-merge [ENTRY=<entry>]      merge one entry, if it replays cleanly
queue-merge:
	@$(QUEUE) merge $(ENTRY)

# ---- inspecting it --------------------------------------------------------

## queue-list                       the pending queue, in merge order
queue-list:
	@$(QUEUE) list

## queue-status                     where the branch is, what is waiting, what is stuck
queue-status:
	@$(QUEUE) status

## queue-show ENTRY=<entry>         one entry in full, with its conflict note
queue-show:
	@$(QUEUE) show $(ENTRY) $(ARGS)

## queue-diff ENTRY=<entry>         what that entry would bring; ARGS=--stat
queue-diff:
	@$(QUEUE) diff $(ENTRY) $(ARGS)

## queue-check [ENTRY=<entry>]      replay the queue to find conflicts before the drain
queue-check:
	@$(QUEUE) check $(ENTRY)

## queue-notes                      every conflict resolution recorded so far
queue-notes:
	@$(QUEUE) notes

## queue-history [ARGS=-20]         the branch's log, and the entry behind each commit
queue-history:
	@$(QUEUE) history $(ARGS)

## queue-log                        what the queue has merged or withdrawn
queue-log:
	@$(QUEUE) log

## queue-sessions ENTRY=<e|commit>  the session transcripts that worked on an entry
queue-sessions:
	@$(QUEUE) sessions $(ENTRY)

## queue-audit ENTRY=<e|commit>     each of those through `chaland audit`; ARGS= to it
queue-audit:
	@$(QUEUE) audit $(ENTRY) $(ARGS)

# ---- for the draining agent ----------------------------------------------

## queue-next                       the head of the queue, tab-separated
queue-next:
	@$(QUEUE) next

## queue-landing-message ENTRY=<e>  the message plus the provenance trailer
queue-landing-message:
	@$(QUEUE) landing-message $(ENTRY)

## queue-complete ENTRY=<entry>     mark an entry drained -- bookkeeping, not for hand use
queue-complete:
	@$(QUEUE) complete $(ENTRY)

# ---- for the reviewing agent ---------------------------------------------

## queue-id                         a fresh id in the queue's format, for a Reviewed: stamp
#
# Not a claim. `queue-worktree` and `queue-submit` take ids under git's
# must-not-exist ref lock, because an entry id has to be unique; this only
# reads the clock. Use it to stamp something, never to name an entry.
queue-id:
	@$(QUEUE) id

# ---- the queue's own tests ------------------------------------------------

## queue-selftest                   run the queue against a throwaway repository
queue-selftest:
	@$(QUEUE_DIR)test.sh

# An alias, because `queue-test` is what a reader guesses. `queue-selftest` is
# the documented name: it says whose tests these are, in a repository whose own
# `make test` is the thing you usually want.
queue-test: queue-selftest

# ---- the escape hatch -----------------------------------------------------

## queue ARGS="show api-fix ..."    run queue.sh directly, positionally
#
# The variable convention cannot express every ad-hoc git log/git diff flag
# combination, and queue.sh keeps the positional interface it always had.
queue:
	@$(QUEUE) $(ARGS)

# Every one of these is a report rather than a file, and a repository that
# happens to contain a directory called `queue` would otherwise make `make
# queue` a no-op.
.PHONY: queue queue-help queue-worktree queue-handover queue-handovers \
        queue-submit queue-message queue-drop queue-drain queue-merge \
        queue-list queue-status queue-show queue-diff queue-check queue-notes \
        queue-history queue-log queue-sessions queue-audit queue-next \
        queue-landing-message queue-complete queue-id queue-selftest queue-test
