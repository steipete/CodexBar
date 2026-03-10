# CodexBar Makefile — thin wrappers around Scripts/*.sh
# Run `make` or `make help` to see available targets.

# Pull version from version.env for targets that need it
include version.env
export MARKETING_VERSION
export BUILD_NUMBER

# Auto-detect Developer ID signing identity to avoid keychain prompts on rebuild.
# Override: make run APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"
APP_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
export APP_IDENTITY

.PHONY: help build build-release test run run-test lint format \
        sign package release appcast check-release validate-changelog \
        check-upstream clean

# ── Default ──────────────────────────────────────────────────────────
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' Makefile | \
		awk -F ':.*## ' '{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── Core Development ────────────────────────────────────────────────
build: ## Debug build
	swift build

build-release: ## Release build
	swift build -c release

test: ## Run full test suite
	swift test

run: ## Build, package, and launch (main dev workflow)
	./Scripts/compile_and_run.sh

run-test: ## Build with tests, package, and launch
	./Scripts/compile_and_run.sh --test

# ── Code Quality ────────────────────────────────────────────────────
lint: ## SwiftFormat --lint + SwiftLint --strict (check only)
	./Scripts/lint.sh lint

format: ## SwiftFormat auto-fix
	./Scripts/lint.sh format

# ── Release ─────────────────────────────────────────────────────────
sign: ## Sign + notarize for distribution
	./Scripts/sign-and-notarize.sh

package: ## Build release binary and create CodexBar.app bundle
	./Scripts/package_app.sh

release: ## Full release pipeline
	./Scripts/release.sh

appcast: ## Generate Sparkle appcast (requires args: make appcast ARGS="<zip> <url>")
	@if [ -z "$(ARGS)" ]; then \
		echo "Usage: make appcast ARGS=\"<path-to-zip> <download-url>\""; \
		echo "  e.g. make appcast ARGS=\"CodexBar-0.18.0.zip https://example.com/CodexBar-0.18.0.zip\""; \
		exit 1; \
	fi
	./Scripts/make_appcast.sh $(ARGS)

# ── Validation & Checks ────────────────────────────────────────────
check-release: ## Verify GitHub release assets
	./Scripts/check-release-assets.sh

validate-changelog: ## Validate CHANGELOG.md for current version
	./Scripts/validate_changelog.sh $(MARKETING_VERSION)

check-upstream: ## Check upstream repos for changes
	./Scripts/check_upstreams.sh

# ── Utilities ───────────────────────────────────────────────────────
clean: ## Clean build artifacts
	rm -rf .build CodexBar.app
