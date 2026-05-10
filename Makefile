SHELL := /bin/bash

.PHONY: build check docs-list format lint release restart start start-debug start-release stop test test-live test-tty

start:
	./Scripts/compile_and_run.sh

start-debug:
	./Scripts/compile_and_run.sh

start-release:
	./Scripts/package_app.sh release
	pkill -x CodexBar || pkill -f CodexBar.app || true
	cd /Users/steipete/Projects/codexbar && open -n /Users/steipete/Projects/codexbar/CodexBar.app

restart: start

stop:
	pkill -x CodexBar || pkill -f CodexBar.app || true

check lint:
	./Scripts/lint.sh lint

format:
	./Scripts/lint.sh format

docs-list:
	node Scripts/docs-list.mjs

build:
	swift build

test:
	swift test

test-tty:
	swift test --filter TTYIntegrationTests

test-live:
	LIVE_TEST=1 swift test --filter LiveAccountTests

release:
	./Scripts/package_app.sh release
