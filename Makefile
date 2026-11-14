HOSTS  := $(notdir $(wildcard hosts/*))
HOST   ?= manaan
SYSTEM := x86_64-linux
NIX    := nix --extra-experimental-features 'nix-command flakes'

# Where the tests' Nix runs: Nix itself, or on a Mac without it, Nix in an arm64
# container, its store kept in a volume between runs. Nix only builds there; the
# system tests boot what it built in QEMU on the Mac itself, under HVF.
define LOCAL_NIX_CONFIG
experimental-features = nix-command flakes
sandbox = false
filter-syscalls = false
endef
# Mounted at their own paths, not /repo: in a worktree (the merge queue runs these
# in one) .git points into the main checkout's .git by absolute path, and that
# records the worktree's path in turn.
GIT_COMMON := $(shell git rev-parse --path-format=absolute --git-common-dir)
# out/ is the one place it writes: the system tests' images are copied there.
# fmt is the exception, which rewrites the checkout itself.
SRC_MODE := ro
# The daemon's socket is in the container, not the volume, so two runs at once
# each talk to their own daemon rather than one finding the other's gone.
DOCKER_NIX = docker run --rm --platform linux/arm64 -w "$(CURDIR)" -v "$(CURDIR)":"$(CURDIR)":$(SRC_MODE) \
	-v "$(GIT_COMMON)":"$(GIT_COMMON)":ro -v "$(CURDIR)/out":"$(CURDIR)/out" \
	-v machine-configs-nix:/nix -e NIX_CONFIG -e NIX_DAEMON_SOCKET_PATH=/tmp/nix-daemon.socket \
	nixos/nix:latest
ifneq ($(shell command -v nix 2>/dev/null),)
in-nix = $(1)
TEST_NIX := $(NIX)
TEST_FLAKE := .
TEST_SYSTEM := $(SYSTEM)
else
export NIX_CONFIG := $(LOCAL_NIX_CONFIG)
# Only the daemon runs as root, so only it can write the store: the command runs
# as a user of its own, which the store refuses as on any multi-user Nix. The
# volume's store was root's alone before, and the daemon takes it over as it is.
# The daemon's settings stay with the daemon; given to the client too, it warns
# that an untrusted user may not set them.
in-nix = $(DOCKER_NIX) sh -c 'nix-daemon >/dev/null 2>&1 & \
	until nix store info --store daemon >/dev/null 2>&1; do kill -0 $$! || exit 1; sleep 0.1; done; \
	install -d -o 1000 -g 1000 /tmp/home && \
	exec chroot --userspec=1000:1000 --skip-chdir / env HOME=/tmp/home NIX_REMOTE=daemon \
		NIX_CONFIG="experimental-features = nix-command flakes" sh -c "$$1"' \
	- 'git config --global --add safe.directory "*" && $(1)'
TEST_NIX := nix
TEST_FLAKE := git+file://$(CURDIR)
TEST_SYSTEM := aarch64-linux
endif

.DEFAULT_GOAL := help
.PHONY: help check release signed update fmt fmt-check build build-all test-unit test-integration system-image test-system test-system-all vm iso isos lock status

help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-17s %s\n", $$1, $$2}'

check: fmt-check build-all test-unit test-integration test-system-all ## Everything CI runs before releasing

# Machines deploy origin's release branch, so it only moves to a commit that is on
# main, is signed by an admin, and passes check. A plain push only fast-forwards, so a
# late run can't move it back.
release: signed check ## Fast-forward origin's release to HEAD, once HEAD is signed and on origin's main
	git fetch --quiet origin main
	@git merge-base --is-ancestor HEAD FETCH_HEAD || { echo "HEAD is not on origin's main; push it there first"; exit 1; }
	git push origin HEAD:refs/heads/release

# The machines refuse a release not signed by a key in ssh/, so release refuses it
# first. The allowed signers are made the way modules/self-upgrade makes the machines'
# (each key, as its user, for git only), in awk rather than Nix so this needs no eval.
signed: ## Check HEAD is signed by an admin's SSH key, in ssh/
	@signers=$$(mktemp) && trap 'rm -f "$$signers"' EXIT && \
	for f in ssh/*; do \
		[ -f "$$f" ] && [ "$${f##*/}" != default.nix ] || continue; \
		awk -v user="$${f##*/}" '!/^[[:space:]]*(#|$$)/ { sub(/^[[:space:]]+/, ""); print user " namespaces=\"git\" " $$0 }' "$$f"; \
	done >"$$signers" && \
	git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$$signers" verify-commit HEAD || \
		{ echo "HEAD is not signed by a key in ssh/; machines would refuse it, so it is not released"; exit 1; }

# The update can't be signed where it is made, so it is only proposed: the user lands
# flake-update through the merge queue, whose squash commit they sign, and that releases it.
update: ## Update flake.lock; if an input moved and check passes, push it to origin's flake-update branch
	@before=$$(git rev-parse HEAD); \
	$(NIX) flake update --commit-lock-file --option commit-lock-file-summary 'flake: update inputs' || exit 1; \
	if [ "$$(git rev-parse HEAD)" = "$$before" ]; then echo "flake.lock is up to date"; exit 0; fi; \
	$(MAKE) --no-print-directory check && \
	git push --force origin HEAD:refs/heads/flake-update && \
	echo "pushed to origin's flake-update; land it through the merge queue to release it"

# The formatter is the flake's, so without Nix it runs in Docker like the tests.
fmt: SRC_MODE := rw
fmt: ## Format all nix files
	$(call in-nix,$(TEST_NIX) fmt -- $$(git ls-files "*.nix"))

fmt-check: ## Check formatting, and that no nix file is over 300 lines
	$(call in-nix,$(TEST_NIX) fmt -- --check $$(git ls-files "*.nix"))
	@git ls-files '*.nix' | xargs wc -l | awk '$$2 != "total" && $$1 > 300 { print $$2 " is " $$1 " lines; split it to 300 or fewer"; long = 1 } END { exit long }'

build: ## Build HOST's system
	$(NIX) build -L --no-link .#nixosConfigurations.$(HOST).config.system.build.toplevel

build-all:
	@for h in $(HOSTS); do $(MAKE) --no-print-directory build HOST=$$h || exit 1; done

# The tests, in three categories (see flake.nix). Without Nix, they run in Docker.
test-unit: ## One script or module on its own, against stubs, one case per behaviour (seconds)
	$(call in-nix,$(TEST_NIX) build -L --no-link $(TEST_FLAKE)#tests.unit)

test-integration: ## Scripts and modules together: rollback across reboots, git through the wrapper, each host's whole config (no VM)
	$(call in-nix,$(TEST_NIX) build -L --no-link $(TEST_FLAKE)#tests.integration)

# The system tests: Nix builds what they boot into out/system/HOST/image, copied
# out of the store so QEMU can read it without Nix, and only again once it
# changes. The tests themselves are pytest, in a venv of their own.
IMAGE := out/system/$(HOST)/image
VENV  := out/system/venv
system-image: ## Build what the system tests boot for HOST (its installer ISO, host.json) into out/system/HOST/image
	@mkdir -p out/system/$(HOST)
	$(call in-nix,p=$$($(TEST_NIX) build -L --no-link --print-out-paths $(TEST_FLAKE)#tests.system.$(HOST)) && \
		if [ "$$(cat $(IMAGE)/source 2>/dev/null)" != "$$p" ]; then \
			rm -rf $(IMAGE) && mkdir $(IMAGE) && cp -L --no-preserve=mode "$$p"/* $(IMAGE) && echo "$$p" > $(IMAGE)/source; \
		fi)

$(VENV)/stamp: tests/system/requirements.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --requirement $<
	touch $@

test-system: system-image $(VENV)/stamp ## Boot HOST in QEMU and test it from outside: installing it from the ISO, the host, upgrading it (ARGS for pytest)
	PYTHONDONTWRITEBYTECODE=1 $(VENV)/bin/pytest tests/system --image $(IMAGE) $(ARGS)

test-system-all:
	@for h in $(HOSTS); do $(MAKE) --no-print-directory test-system HOST=$$h || exit 1; done

vm: system-image $(VENV)/stamp ## Boot HOST's system test image, installed, and leave it running to SSH into
	PYTHONDONTWRITEBYTECODE=1 $(VENV)/bin/python tests/system/vm.py $(IMAGE)

iso: ## Build HOST's self-installing ISO into out/
	mkdir -p out
	install -m644 "$$($(NIX) build -L --no-link --print-out-paths .#$(HOST)-installer)"/iso/*.iso out/

isos: ## Build every host's self-installing ISO into out/
	@for h in $(HOSTS); do $(MAKE) --no-print-directory iso HOST=$$h || exit 1; done

lock: ## Update flake.lock
	$(NIX) flake update

status: ## Show HOST's upgrade and healthcheck state
	ssh $(HOST) 'systemctl status --no-pager healthcheck self-upgrade-verify self-upgrade self-upgrade.timer; \
		echo; echo "deployed: $$(cat /var/lib/self-upgrade/rev 2>/dev/null)"; \
		echo "pending:  $$(cat /var/lib/self-upgrade/pending 2>/dev/null)"; \
		echo "bad revs:"; cat /var/lib/self-upgrade/bad-revs 2>/dev/null'

# The merge queue's queue-* targets; `make queue-help` lists them. Each entry
# lands only once these pass on the tree it would land as.
QUEUE_TEST := make --no-print-directory test-unit test-integration
include queue/queue.mk
