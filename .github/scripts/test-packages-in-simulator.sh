#!/bin/bash
# Runs `xcodebuild test` for each named package under Packages/ in the iOS Simulator whose UDID is given first, and
# fails at the end if any package failed. Used by app.yml's jobs, which split the packages between them.
#
#   .github/scripts/test-packages-in-simulator.sh <simulator-udid> <package>...
#
# Xcode names a single-product package's scheme after the product and adds "<Package>-Package" when there are
# several; the -Package scheme is preferred because it holds every test target. Indexing while building is off
# (COMPILER_INDEX_STORE_ENABLE=NO): nothing on CI reads the index, and it costs compile time.
set -uo pipefail
sim="$1"
shift
failed=()
for pkg in "$@"; do
  dir="Packages/$pkg"
  echo "::group::$pkg"
  if [ ! -f "$dir/Package.swift" ]; then
    echo "::error::$dir has no Package.swift"
    failed+=("$pkg")
    echo "::endgroup::"
    continue
  fi
  # Tolerant probe: xcodebuild can print package-resolution lines before the JSON, so parse from the first "{" and
  # fall back to the folder name.
  schemes="$(cd "$dir" && xcodebuild -list -json 2>/dev/null | python3 -c 'import json, sys; s = sys.stdin.read(); i = s.find("{"); d = json.loads(s[i:]) if i >= 0 else {}; print("\n".join((d.get("workspace") or d.get("project") or {}).get("schemes", [])))' || true)"
  if grep -qx "$pkg-Package" <<<"$schemes"; then scheme="$pkg-Package"; else scheme="$pkg"; fi
  echo "scheme: $scheme"
  raw="${RUNNER_TEMP:-/tmp}/$pkg-test.log"
  # AppUI's tests run one at a time. Nearly all of them are main-actor bound, and Swift Testing starts every test at
  # once, so in the Simulator they queue for the main actor and the wait counts against each test's own time limit:
  # with about 240 tests a passing run already had a median of 45 s and a slowest of 56 s against the 60 s limits,
  # and larger suites went over. One at a time, a limit measures only the test. The other packages' tests aren't
  # main-actor bound and stay parallel.
  parallel=()
  if [ "$pkg" = AppUI ]; then parallel=(-parallel-testing-enabled NO); fi
  if ! (cd "$dir" && xcodebuild test -scheme "$scheme" -destination "platform=iOS Simulator,id=$sim" \
          "${parallel[@]}" COMPILER_INDEX_STORE_ENABLE=NO | tee "$raw" | xcbeautify --renderer github-actions); then
    failed+=("$pkg")
    # xcbeautify shortens Swift Testing failures to "Recorded an issue" and drops compiler crashes, so print the raw
    # lines that name the test and the expectation that failed, any compile error, and a crashed compiler's stack
    # dump (which names the file and declaration it was type-checking).
    echo "--- $pkg: failures from the raw xcodebuild output ---"
    grep -E 'recorded an issue|Expectation failed|failed after|error:' "$raw" | head -n 80 || true
    grep -E -A 12 'Stack dump:|Please submit a bug report|Assertion failed|Segmentation fault|While (evaluating|type-checking|emitting|SILGen)' "$raw" | head -n 120 || true
  fi
  echo "::endgroup::"
done
if [ "${#failed[@]}" -gt 0 ]; then
  echo "::error::Package tests failed in the iOS Simulator: ${failed[*]}"
  exit 1
fi
