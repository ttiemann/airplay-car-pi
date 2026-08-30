SHELL := /bin/bash

IMAGE_NAME ?= airplay-car-pi-test
DOCKERFILE ?= Dockerfile
PI_USER ?= airplay
PI_HOST ?= airplay-car
PI_PATH ?= /home/$(PI_USER)
SSH_CONNECT_TIMEOUT ?= 20
COPY_RETRIES ?= 5
WAIT_SSH_RETRIES ?= 36
WAIT_SSH_INTERVAL ?= 5
RELEASE_VERSION ?=
SNAPSHOT_ID ?=
INSTALL_BUNDLE ?= dist/install.sh

.PHONY: help check lint unit integration-airplay perf security changelog bundle-install package release-prep tag-release backup-remote rollback-remote remote-writable-root remote-readonly-root build run rerun diagnose-container test verify-packages test-no-network shell copy-scripts remote-install wait-for-ssh remote-diagnose deploy clean

help:
	@echo "Available targets:"
	@echo "  make check                       - Validate install.sh syntax"
	@echo "  make lint                        - Run shellcheck if installed"
	@echo "  make unit                        - Run isolated unit tests for installer logic"
	@echo "  make integration-airplay         - Run real sender flow test against target Pi"
	@echo "  make perf                        - Run regression/performance tests on target Pi"
	@echo "  make security                    - Run security checks (shellcheck all, secrets, trivy, gitleaks)"
	@echo "  make changelog VERSION=vX.Y.Z    - Generate dist changelog from git history"
	@echo "  make bundle-install              - Build self-contained dist/install.sh for curl | bash installs"
	@echo "  make package VERSION=vX.Y.Z      - Build release tar.gz/zip artifacts in dist/"
	@echo "  make release-prep VERSION=vX.Y.Z - Generate changelog and packages together"
	@echo "  make tag-release VERSION=vX.Y.Z  - Create annotated git tag locally"
	@echo "  make build                       - Build Docker image"
	@echo "  make run                         - Run installer in Docker"
	@echo "  make rerun                       - Run installer twice (idempotency check)"
	@echo "  make diagnose-container          - Run diagnose.sh in Docker"
	@echo "  make verify-packages             - Verify expected packages in container"
	@echo "  make test-no-network             - Run installer without network (negative test)"
	@echo "  make test                        - Run check, lint, build, run, verify-packages"
	@echo "  make shell                       - Open shell in built image"
	@echo "  make copy-scripts                - Copy install.sh and diagnose.sh to Raspberry Pi"
	@echo "  make backup-remote               - Save remote rollback snapshot before promotion"
	@echo "  make rollback-remote SNAPSHOT_ID=<id> - Restore a saved remote rollback snapshot"
	@echo "  make remote-writable-root         - Disable read-only overlay so updates can be installed (needs reboot)"
	@echo "  make remote-readonly-root         - Re-enable read-only overlay after updates (needs reboot)"
	@echo "  make remote-install              - Run installer on Raspberry Pi over SSH"
	@echo "  make wait-for-ssh                - Wait until SSH on Raspberry Pi is reachable"
	@echo "  make remote-diagnose             - Run diagnostics on Raspberry Pi over SSH"
	@echo "  make deploy                      - Copy scripts, run installer, then diagnostics"
	@echo "  make clean                       - Remove Docker image"

check:
	bash -n install.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck install.sh; \
	else \
		echo "shellcheck not found, skipping lint"; \
	fi

unit:
	bash tests/unit/install_unit_tests.sh

integration-airplay:
	bash tests/integration/airplay_sender_flow_test.sh

perf:
	bash tests/regression/perf_test.sh

security:
	bash tests/security/security_check.sh

changelog:
	@test -n "$(RELEASE_VERSION)$(VERSION)" || (echo "Set VERSION=vX.Y.Z" && exit 1)
	@echo "$(or $(VERSION),$(RELEASE_VERSION))" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$' || (echo "VERSION must match vX.Y.Z" && exit 1)
	bash scripts/release/generate_changelog.sh $(or $(VERSION),$(RELEASE_VERSION))

bundle-install:
	bash scripts/release/bundle_install.sh $(INSTALL_BUNDLE)

package:
	@test -n "$(RELEASE_VERSION)$(VERSION)" || (echo "Set VERSION=vX.Y.Z" && exit 1)
	@echo "$(or $(VERSION),$(RELEASE_VERSION))" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$' || (echo "VERSION must match vX.Y.Z" && exit 1)
	bash scripts/release/package_release.sh $(or $(VERSION),$(RELEASE_VERSION))

release-prep: changelog package

tag-release:
	@test -n "$(RELEASE_VERSION)$(VERSION)" || (echo "Set VERSION=vX.Y.Z" && exit 1)
	@echo "$(or $(VERSION),$(RELEASE_VERSION))" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$' || (echo "VERSION must match vX.Y.Z" && exit 1)
	git tag -a $(or $(VERSION),$(RELEASE_VERSION)) -m "Release $(or $(VERSION),$(RELEASE_VERSION))"

build:
	docker build -f $(DOCKERFILE) -t $(IMAGE_NAME) .

run: build
	docker run --rm -it $(IMAGE_NAME)

rerun: build
	docker run --rm -it $(IMAGE_NAME)
	docker run --rm -it $(IMAGE_NAME)

diagnose-container: build
	docker run --rm -it $(IMAGE_NAME) bash -lc "/app/install.sh >/dev/null && /app/diagnose.sh"

verify-packages: build
	docker run --rm -it $(IMAGE_NAME) bash -lc "/app/install.sh >/dev/null && dpkg -l alsa-utils avahi-daemon shairport-sync"

test-no-network: build
	docker run --rm -it --network none $(IMAGE_NAME)

test: check lint build run verify-packages

shell: build
	docker run --rm -it --entrypoint bash $(IMAGE_NAME)

backup-remote:
	bash scripts/deploy/create_backup.sh

rollback-remote:
	@test -n "$(SNAPSHOT_ID)" || (echo "Set SNAPSHOT_ID=<timestamp>" && exit 1)
	bash scripts/deploy/rollback_backup.sh $(SNAPSHOT_ID)

remote-writable-root:
	PI_USER=$(PI_USER) PI_HOST=$(PI_HOST) SSH_CONNECT_TIMEOUT=$(SSH_CONNECT_TIMEOUT) bash scripts/deploy/set_overlay_mode.sh writable

remote-readonly-root:
	PI_USER=$(PI_USER) PI_HOST=$(PI_HOST) SSH_CONNECT_TIMEOUT=$(SSH_CONNECT_TIMEOUT) bash scripts/deploy/set_overlay_mode.sh readonly

copy-scripts:
	@for i in $$(seq 1 $(COPY_RETRIES)); do \
		echo "Copy attempt $$i/$(COPY_RETRIES)..."; \
		if scp -o ConnectTimeout=$(SSH_CONNECT_TIMEOUT) ./install.sh ./diagnose.sh $(PI_USER)@$(PI_HOST):$(PI_PATH)/; then \
			exit 0; \
		fi; \
		if [[ $$i -lt $(COPY_RETRIES) ]]; then \
			echo "Copy failed, retrying in 5s..."; \
			sleep 5; \
		fi; \
	done; \
	echo "copy-scripts failed after $(COPY_RETRIES) attempts"; \
	exit 1

remote-install:
	ssh -tt -o ConnectTimeout=$(SSH_CONNECT_TIMEOUT) $(PI_USER)@$(PI_HOST) "chmod +x $(PI_PATH)/install.sh && sudo $(PI_PATH)/install.sh"

wait-for-ssh:
	@echo "Waiting for SSH on $(PI_HOST):22..."
	@for i in $$(seq 1 $(WAIT_SSH_RETRIES)); do \
		if nc -z $(PI_HOST) 22 >/dev/null 2>&1; then \
			echo "SSH port is reachable"; \
			exit 0; \
		fi; \
		echo "Attempt $$i/$(WAIT_SSH_RETRIES): SSH not reachable yet, retrying in $(WAIT_SSH_INTERVAL)s..."; \
		sleep $(WAIT_SSH_INTERVAL); \
	done; \
	echo "Timed out waiting for SSH on $(PI_HOST):22"; \
	exit 1

remote-diagnose:
	ssh -tt -o ConnectTimeout=$(SSH_CONNECT_TIMEOUT) $(PI_USER)@$(PI_HOST) "chmod +x $(PI_PATH)/diagnose.sh && $(PI_PATH)/diagnose.sh"

deploy: wait-for-ssh copy-scripts remote-install wait-for-ssh remote-diagnose

clean:
	docker rmi $(IMAGE_NAME) || true
