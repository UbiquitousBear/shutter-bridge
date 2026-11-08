.PHONY: spike test test-docker fixtures hooks open app clean

FIXTURE_TESTS := Packages/PTPKit/Tests/PTPKitTests/Fixtures
SWIFT_IMAGE   := swift:6.4-noble

# Generate the spike's Xcode project (requires `brew install xcodegen`).
spike:
	cd Spike && xcodegen generate

# Every package under Packages/ that has a Package.swift, so a new one is picked up without editing this.
PACKAGE_LOOP = set -e; for p in Packages/*/; do [ -f "$$p/Package.swift" ] || continue; \
	echo "== $$p"; (cd "$$p" && swift test); done

# Run every package's tests; works on macOS and on Linux with a Swift 6.2+ toolchain (Apple-only code is behind
# `#if canImport(...)`, so Linux builds the rest).
test:
	@$(PACKAGE_LOOP)

# The same tests in the official Swift image (Swift 6.4, as in Xcode 27), for machines without a toolchain.
test-docker:
	docker run --rm -v "$(CURDIR)":/src -w /src $(SWIFT_IMAGE) sh -c '$(PACKAGE_LOOP)'

# Copy captured camera bytes into the PTPKit test bundle under the names its fixture tests look for:
# Fixtures/a7c2/<link>/<name>.bin -> $(FIXTURE_TESTS)/a7c2-<link>-<name>.bin
fixtures:
	@python3 scripts/redact-fixtures.py
	@n=0; for f in Fixtures/a7c2/*/*.bin; do \
		[ -f "$$f" ] || continue; \
		link=$$(basename "$$(dirname "$$f")"); name=$$(basename "$$f"); \
		case "$$name" in objectproplist*) echo "  $$f skipped: MTP property lists stay out of the repo (Fixtures/README.md, Rules)"; continue;; esac; \
		cp "$$f" "$(FIXTURE_TESTS)/a7c2-$$link-$$name"; n=$$((n + 1)); \
		echo "  $$f -> $(FIXTURE_TESTS)/a7c2-$$link-$$name"; \
	done; echo "$$n fixture(s) copied"

# Enable the repo's git hooks for this clone (owner-only commit attribution; see AGENTS.md).
hooks:
	git config core.hooksPath .githooks
	@echo "git hooks enabled (.githooks)"

open: spike
	open Spike/Spike.xcodeproj

# Open the production app's project (committed, hand-written; nothing to generate).
app:
	open App/ShutterBridge.xcodeproj

clean:
	rm -rf Spike/Spike.xcodeproj Packages/*/.build
