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
DOCKER_NIX := docker run --rm --platform linux/arm64 -v "$(CURDIR)":/repo:ro \
	-v machine-configs-nix:/nix -e NIX_CONFIG nixos/nix:latest
LOCAL_CHECKS = git+file:///repo\#checks.aarch64-linux

.DEFAULT_GOAL := help
.PHONY: help check fmt fmt-check build build-all test-scripts test test-all test-local vm iso lock enroll secret rekey status

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

check: fmt-check build-all test-scripts test-all ## Everything CI runs before releasing

fmt: ## Format all nix files
	$(NIX) fmt -- $$(git ls-files '*.nix')

fmt-check:
	$(NIX) fmt -- --check $$(git ls-files '*.nix')

build: ## Build HOST's system
	$(NIX) build -L --no-link .#nixosConfigurations.$(HOST).config.system.build.toplevel

build-all:
	@for h in $(HOSTS); do $(MAKE) --no-print-directory build HOST=$$h || exit 1; done

test-scripts: ## Run the self-upgrade, installer and smoke test scripts against stubs, one case per behaviour (no VM)
	$(NIX) build -L --no-link $(foreach s,upgrade verify install smoke-test,.#checks.$(SYSTEM).script-$(s))

test: ## Boot HOST in VMs: smoke and network tests, install from the ISO, upgrades (needs x86_64 Linux with KVM)
	$(NIX) build -L --no-link $(foreach t,$(HOST) $(HOST)-installer $(HOST)-upgrade,.#checks.$(SYSTEM).$(t))

test-all:
	@for h in $(HOSTS); do $(MAKE) --no-print-directory test HOST=$$h || exit 1; done

test-local: export NIX_CONFIG := $(LOCAL_NIX_CONFIG)
test-local: ## On a Mac, without Nix: HOST's tests on aarch64 in Docker Desktop (give it 16 GB); CI runs them on x86_64
	$(DOCKER_NIX) sh -c 'git config --global --add safe.directory /repo && \
		nix build -L --no-link $(foreach s,upgrade verify install smoke-test,$(LOCAL_CHECKS).script-$(s)) && \
		nix build -L --no-link $(foreach t,$(HOST) $(HOST)-installer $(HOST)-upgrade,$(LOCAL_CHECKS).$(t))'

vm: ## Interactive VM test driver for HOST
	$(NIX) run .#checks.$(SYSTEM).$(HOST).driverInteractive

iso: ## Build HOST's self-installing ISO into out/
	mkdir -p out
	install -m644 "$$($(NIX) build -L --no-link --print-out-paths .#$(HOST)-installer)"/iso/*.iso out/

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

status: ## Show HOST's upgrade and smoke test state
	ssh $(HOST) 'systemctl status --no-pager smoke-test self-upgrade-verify self-upgrade self-upgrade.timer; \
		echo; echo "deployed: $$(cat /var/lib/self-upgrade/rev 2>/dev/null)"; \
		echo "pending:  $$(cat /var/lib/self-upgrade/pending 2>/dev/null)"; \
		echo "bad revs:"; cat /var/lib/self-upgrade/bad-revs 2>/dev/null'
