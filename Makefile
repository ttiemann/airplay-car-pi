SHELL := /bin/bash

IMAGE_NAME ?= airplay-car-pi-test
DOCKERFILE ?= Dockerfile
PI_USER ?= pi
PI_HOST ?= raspberrypi.local
PI_PATH ?= ~

.PHONY: help check lint build run rerun diagnose-container test verify-packages test-no-network shell copy-scripts remote-install remote-diagnose deploy clean

help:
	@echo "Available targets:"
	@echo "  make check              - Validate install.sh syntax"
	@echo "  make lint               - Run shellcheck if installed"
	@echo "  make build              - Build Docker image"
	@echo "  make run                - Run installer in Docker"
	@echo "  make rerun              - Run installer twice (idempotency check)"
	@echo "  make diagnose-container - Run diagnose.sh in Docker"
	@echo "  make verify-packages    - Verify expected packages in container"
	@echo "  make test-no-network    - Run installer without network (negative test)"
	@echo "  make test               - Run check, lint, build, run, verify-packages"
	@echo "  make shell              - Open shell in built image"
	@echo "  make copy-scripts       - Copy install.sh and diagnose.sh to Raspberry Pi"
	@echo "  make remote-install     - Run installer on Raspberry Pi over SSH"
	@echo "  make remote-diagnose    - Run diagnostics on Raspberry Pi over SSH"
	@echo "  make deploy             - Copy scripts, run installer, then diagnostics"
	@echo "  make clean              - Remove Docker image"

check:
	bash -n install.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck install.sh; \
	else \
		echo "shellcheck not found, skipping lint"; \
	fi

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
	scp ./install.sh ./diagnose.sh $(PI_USER)@$(PI_HOST):$(PI_PATH)/

remote-install:
	ssh $(PI_USER)@$(PI_HOST) "chmod +x $(PI_PATH)/install.sh && sudo $(PI_PATH)/install.sh"

remote-diagnose:
	ssh $(PI_USER)@$(PI_HOST) "chmod +x $(PI_PATH)/diagnose.sh && $(PI_PATH)/diagnose.sh"

deploy: copy-scripts remote-install remote-diagnose

clean:
	docker rmi $(IMAGE_NAME) || true
