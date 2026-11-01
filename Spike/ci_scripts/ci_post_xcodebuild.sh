#!/bin/sh
# Xcode Cloud runs this after xcodebuild. After an archive, fail the build if the app lost the Hotspot
# Configuration entitlement: signing and TestFlight processing would succeed without it, and the day-9 join to
# the camera's access point would then fail on the phone with no other warning.
set -eu

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0

check() {
  app="$1"
  [ -n "$app" ] && [ -d "$app" ] || return 0
  if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'com.apple.developer.networking.HotspotConfiguration'; then
    echo "entitlements OK: $app"
  else
    echo "error: $app is signed without com.apple.developer.networking.HotspotConfiguration" >&2
    exit 1
  fi
}

check "$(find "${CI_ARCHIVE_PATH:-/nonexistent}/Products/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | head -n 1)"
check "${CI_APP_STORE_SIGNED_APP_PATH:-}"
