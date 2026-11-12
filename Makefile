HOSTS  := $(notdir $(wildcard hosts/*))
HOST   ?= manaan
SYSTEM := x86_64-linux
NIX    := nix --extra-experimental-features 'nix-command flakes'
AGENIX := $(NIX) run github:ryantm/agenix --

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
DOCKER_NIX := docker run --rm --platform linux/arm64 -w "$(CURDIR)" -v "$(CURDIR)":"$(CURDIR)":ro \
	-v "$(GIT_COMMON)":"$(GIT_COMMON)":ro -v "$(CURDIR)/out":"$(CURDIR)/out" \
	-v machine-configs-nix:/nix -e NIX_CONFIG nixos/nix:latest
ifneq ($(shell command -v nix 2>/dev/null),)
in-nix = $(1)
TEST_NIX := $(NIX)
TEST_FLAKE := .
TEST_SYSTEM := $(SYSTEM)
else
export NIX_CONFIG := $(LOCAL_NIX_CONFIG)
in-nix = $(DOCKER_NIX) sh -c 'git config --global --add safe.directory "*" && $(1)'
TEST_NIX := nix
TEST_FLAKE := git+file://$(CURDIR)
TEST_SYSTEM := aarch64-linux
endif

.DEFAULT_GOAL := help
.PHONY: help check release signed update fmt fmt-check build build-all test-unit test-integration system-image test-system test-system-all vm iso isos lock enroll secret rekey status

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

fmt: ## Format all nix files
	$(NIX) fmt -- $$(git ls-files '*.nix')

fmt-check: ## Check formatting, and that no nix file is over 300 lines
	$(NIX) fmt -- --check $$(git ls-files '*.nix')
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

enroll: ## After HOST's first boot: trust its host key and re-encrypt secrets for it (ADDR=<ip>)
	@test -n "$(ADDR)" || { echo "usage: make enroll HOST=manaan ADDR=<ip>"; exit 1; }
	ssh-keyscan -t ed25519 $(ADDR) 2>/dev/null | cut -d' ' -f2- > hosts/$(HOST)/host_key.pub
	@test -s hosts/$(HOST)/host_key.pub || { echo "no host key from $(ADDR)"; rm -f hosts/$(HOST)/host_key.pub; exit 1; }
	@echo "Check this matches the 'host key:' line the installer printed on the console:"
	@ssh-keygen -l -f hosts/$(HOST)/host_key.pub
	$(MAKE) --no-print-directory rekey
	@echo "Commit and push hosts/$(HOST)/host_key.pub and secrets/; $(HOST) picks them up on its next upgrade."

secret: ## Create or edit secrets/NAME.age
	@test -n "$(NAME)" || { echo "usage: make secret NAME=tailscale-authkey"; exit 1; }
	cd secrets && $(AGENIX) -e $(NAME).age

rekey: ## Re-encrypt all secrets after keys change
	cd secrets && $(AGENIX) -r

status: ## Show HOST's upgrade and healthcheck state
	ssh $(HOST) 'systemctl status --no-pager healthcheck self-upgrade-verify self-upgrade self-upgrade.timer; \
		echo; echo "deployed: $$(cat /var/lib/self-upgrade/rev 2>/dev/null)"; \
		echo "pending:  $$(cat /var/lib/self-upgrade/pending 2>/dev/null)"; \
		echo "bad revs:"; cat /var/lib/self-upgrade/bad-revs 2>/dev/null'

# The merge queue's queue-* targets; `make queue-help` lists them. Each entry
# lands only once these pass on the tree it would land as.
QUEUE_TEST := make --no-print-directory test-unit test-integration
include queue/queue.mk
