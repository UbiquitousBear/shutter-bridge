.PHONY: spike test test-docker fixtures hooks open clean

FIXTURE_TESTS := Packages/PTPKit/Tests/PTPKitTests/Fixtures
SWIFT_IMAGE   := swift:6.4-noble

# Generate the spike's Xcode project (requires `brew install xcodegen`).
spike:
	cd Spike && xcodegen generate

# Run the pure-Swift PTPKit tests; works on macOS and on Linux with a Swift 6.2+ toolchain.
test:
	cd Packages/PTPKit && swift test

# The same tests in the official Swift image (Swift 6.4, as in Xcode 27), for machines without a toolchain.
test-docker:
	docker run --rm -v "$(CURDIR)":/src -w /src/Packages/PTPKit $(SWIFT_IMAGE) swift test

# Copy captured camera bytes into the PTPKit test bundle under the names its fixture tests look for:
# Fixtures/a7c2/<link>/<name>.bin -> $(FIXTURE_TESTS)/a7c2-<link>-<name>.bin
fixtures:
	@python3 scripts/redact-fixtures.py
	@n=0; for f in Fixtures/a7c2/*/*.bin; do \
		[ -f "$$f" ] || continue; \
		link=$$(basename "$$(dirname "$$f")"); name=$$(basename "$$f"); \
		cp "$$f" "$(FIXTURE_TESTS)/a7c2-$$link-$$name"; n=$$((n + 1)); \
		echo "  $$f -> $(FIXTURE_TESTS)/a7c2-$$link-$$name"; \
	done; echo "$$n fixture(s) copied"

# Enable the repo's git hooks for this clone (owner-only commit attribution; see AGENTS.md).
hooks:
	git config core.hooksPath .githooks
	@echo "git hooks enabled (.githooks)"

open: spike
	open Spike/Spike.xcodeproj

clean:
	rm -rf Spike/Spike.xcodeproj Packages/PTPKit/.build
