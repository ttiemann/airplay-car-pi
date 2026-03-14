SHELL := /bin/bash

IMAGE_NAME ?= airplay-car-pi-test
DOCKERFILE ?= Dockerfile
PI_USER ?= pi
PI_HOST ?= raspberrypi.local
PI_PATH ?= /home/$(PI_USER)
SSH_CONNECT_TIMEOUT ?= 20
COPY_RETRIES ?= 5
WAIT_SSH_RETRIES ?= 36
WAIT_SSH_INTERVAL ?= 5

.PHONY: help check lint unit integration-airplay build run rerun diagnose-container test verify-packages test-no-network shell copy-scripts remote-install wait-for-ssh remote-diagnose deploy clean

help:
	@echo "Available targets:"
	@echo "  make check               - Validate install.sh syntax"
	@echo "  make lint                - Run shellcheck if installed"
	@echo "  make unit                - Run isolated unit tests for installer logic"
	@echo "  make integration-airplay - Run real sender flow test against target Pi"
	@echo "  make build               - Build Docker image"
	@echo "  make run                 - Run installer in Docker"
	@echo "  make rerun               - Run installer twice (idempotency check)"
	@echo "  make diagnose-container  - Run diagnose.sh in Docker"
	@echo "  make verify-packages     - Verify expected packages in container"
	@echo "  make test-no-network     - Run installer without network (negative test)"
	@echo "  make test                - Run check, lint, build, run, verify-packages"
	@echo "  make shell               - Open shell in built image"
	@echo "  make copy-scripts        - Copy install.sh and diagnose.sh to Raspberry Pi"
	@echo "  make remote-install      - Run installer on Raspberry Pi over SSH"
	@echo "  make wait-for-ssh        - Wait until SSH on Raspberry Pi is reachable"
	@echo "  make remote-diagnose     - Run diagnostics on Raspberry Pi over SSH"
	@echo "  make deploy              - Copy scripts, run installer, then diagnostics"
	@echo "  make clean               - Remove Docker image"

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
	ssh -o ConnectTimeout=$(SSH_CONNECT_TIMEOUT) $(PI_USER)@$(PI_HOST) "chmod +x $(PI_PATH)/diagnose.sh && $(PI_PATH)/diagnose.sh"

deploy: wait-for-ssh copy-scripts remote-install wait-for-ssh remote-diagnose

clean:
	docker rmi $(IMAGE_NAME) || true
