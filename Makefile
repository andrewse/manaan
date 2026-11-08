HOSTS  := $(notdir $(wildcard hosts/*))
HOST   ?= manaan
SYSTEM := x86_64-linux
NIX    := nix --extra-experimental-features 'nix-command flakes'
AGENIX := $(NIX) run github:ryantm/agenix --

# test-local: Nix in an arm64 container, its store kept in a volume between runs.
# Docker Desktop on an M1 can't nest virtualization, so the test VMs are emulated;
# kvm is claimed only to get the test driver to run them.
define LOCAL_NIX_CONFIG
experimental-features = nix-command flakes
sandbox = false
filter-syscalls = false
system-features = nixos-test benchmark big-parallel kvm
endef
# Mounted at their own paths, not /repo: in a worktree (the merge queue runs these
# in one) .git points into the main checkout's .git by absolute path, and that
# records the worktree's path in turn.
GIT_COMMON := $(shell git rev-parse --path-format=absolute --git-common-dir)
DOCKER_NIX := docker run --rm --platform linux/arm64 -v "$(CURDIR)":"$(CURDIR)":ro \
	-v "$(GIT_COMMON)":"$(GIT_COMMON)":ro \
	-v machine-configs-nix:/nix -e NIX_CONFIG nixos/nix:latest
LOCAL_CHECKS = git+file://$(CURDIR)\#checks.aarch64-linux

.DEFAULT_GOAL := help
.PHONY: help check release update fmt fmt-check build build-all test-scripts test test-all test-local vm iso isos lock enroll secret rekey status

help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

check: fmt-check build-all test-scripts test-all ## Everything CI runs before releasing

# Machines deploy origin's release branch, so it only moves to a commit that is on
# main and passes check. A plain push only fast-forwards, so a late run can't move it back.
release: check ## Fast-forward origin's release to HEAD, once HEAD is on origin's main
	git fetch --quiet origin main
	@git merge-base --is-ancestor HEAD FETCH_HEAD || { echo "HEAD is not on origin's main; push it there first"; exit 1; }
	git push origin HEAD:refs/heads/release

update: ## Update flake.lock; if an input moved and check passes, push it to origin's main and release it
	@before=$$(git rev-parse HEAD); \
	$(NIX) flake update --commit-lock-file --option commit-lock-file-summary 'flake: update inputs' || exit 1; \
	if [ "$$(git rev-parse HEAD)" = "$$before" ]; then echo "flake.lock is up to date"; exit 0; fi; \
	$(MAKE) --no-print-directory check && \
	git push origin HEAD:refs/heads/main && \
	$(MAKE) --no-print-directory release

fmt: ## Format all nix files
	$(NIX) fmt -- $$(git ls-files '*.nix')

fmt-check: ## Check formatting, and that no nix file is over 300 lines
	$(NIX) fmt -- --check $$(git ls-files '*.nix')
	@git ls-files '*.nix' | xargs wc -l | awk '$$2 != "total" && $$1 > 300 { print $$2 " is " $$1 " lines; split it to 300 or fewer"; long = 1 } END { exit long }'

build: ## Build HOST's system
	$(NIX) build -L --no-link .#nixosConfigurations.$(HOST).config.system.build.toplevel

build-all:
	@for h in $(HOSTS); do $(MAKE) --no-print-directory build HOST=$$h || exit 1; done

test-scripts: ## Run the self-upgrade, installer, healthcheck and service command scripts against stubs, one case per behaviour (no VM)
	$(NIX) build -L --no-link $(foreach s,upgrade verify install healthcheck service-command,.#checks.$(SYSTEM).script-$(s))

test: ## Boot HOST in VMs: health, network and git tests, install from the ISO, upgrades (needs x86_64 Linux with KVM)
	$(NIX) build -L --no-link $(foreach t,$(HOST) $(HOST)-installer $(HOST)-upgrade,.#checks.$(SYSTEM).$(t))

test-all:
	@for h in $(HOSTS); do $(MAKE) --no-print-directory test HOST=$$h || exit 1; done

test-local: export NIX_CONFIG := $(LOCAL_NIX_CONFIG)
test-local: ## On a Mac, without Nix: HOST's tests on aarch64 in Docker Desktop (give it 16 GB); CI runs them on x86_64
	$(DOCKER_NIX) sh -c 'git config --global --add safe.directory "*" && \
		nix build -L --no-link $(foreach s,upgrade verify install healthcheck service-command,$(LOCAL_CHECKS).script-$(s)) && \
		nix build -L --no-link $(foreach t,$(HOST) $(HOST)-installer $(HOST)-upgrade,$(LOCAL_CHECKS).$(t))'

vm: ## Interactive VM test driver for HOST
	$(NIX) run .#checks.$(SYSTEM).$(HOST).driverInteractive

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

# The merge queue's queue-* targets; `make queue-help` lists them.
include queue/queue.mk
