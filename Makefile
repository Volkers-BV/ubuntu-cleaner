VERSIONS := 18.04 20.04 22.04 24.04

.PHONY: test test-unit test-integration \
	test-1804 test-2004 test-2204 test-2404 \
	shell-1804 shell-2004 shell-2204 shell-2404 \
	build

## Run all tests across all Ubuntu versions
test: build
	@for v in $(VERSIONS); do \
		echo "=== Testing Ubuntu $$v ==="; \
		docker run --rm --privileged logcleaner-test:$$v bats --recursive tests/; \
	done

## Run unit tests only — no Docker needed (fast dev loop)
test-unit:
	bats --recursive tests/unit/

## Run integration tests in all Ubuntu containers
test-integration: build
	@for v in $(VERSIONS); do \
		echo "=== Integration: Ubuntu $$v ==="; \
		docker run --rm --privileged logcleaner-test:$$v bats --recursive tests/integration/; \
	done

## Run all tests against Ubuntu 18.04 only
test-1804: build
	docker run --rm --privileged logcleaner-test:18.04 bats --recursive tests/

## Run all tests against Ubuntu 20.04 only
test-2004: build
	docker run --rm --privileged logcleaner-test:20.04 bats --recursive tests/

## Run all tests against Ubuntu 22.04 only
test-2204: build
	docker run --rm --privileged logcleaner-test:22.04 bats --recursive tests/

## Run all tests against Ubuntu 24.04 only
test-2404: build
	docker run --rm --privileged logcleaner-test:24.04 bats --recursive tests/

## Drop into interactive shell for debugging (e.g. make shell-2204)
shell-1804:
	docker run --rm -it --privileged logcleaner-test:18.04 bash
shell-2004:
	docker run --rm -it --privileged logcleaner-test:20.04 bash
shell-2204:
	docker run --rm -it --privileged logcleaner-test:22.04 bash
shell-2404:
	docker run --rm -it --privileged logcleaner-test:24.04 bash

## Build all test images
build:
	@for v in $(VERSIONS); do \
		echo "Building Ubuntu $$v..."; \
		docker build -q \
			--build-arg UBUNTU_VERSION=$$v \
			-t logcleaner-test:$$v \
			-f docker/Dockerfile.base . ; \
	done
