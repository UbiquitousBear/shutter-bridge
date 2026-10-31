.PHONY: spike test open clean

# Generate the spike's Xcode project (requires `brew install xcodegen`).
spike:
	cd Spike && xcodegen generate

# Run the pure-Swift PTPKit tests; works on macOS and Linux toolchains.
test:
	cd Packages/PTPKit && swift test

open: spike
	open Spike/Spike.xcodeproj

clean:
	rm -rf Spike/Spike.xcodeproj Packages/PTPKit/.build
