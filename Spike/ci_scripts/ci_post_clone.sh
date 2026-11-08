#!/bin/sh
# Xcode Cloud runs this after cloning, before it resolves packages and builds. It generates the spike's
# .xcodeproj, which is git-ignored.
#
# Xcode Cloud only finds custom build scripts in a ci_scripts directory that sits in the same directory as the
# Xcode project or workspace (Apple: "Writing custom build scripts"). The project is Spike/Spike.xcodeproj, so
# this file must stay at Spike/ci_scripts/. The production app, App/ShutterBridge.xcodeproj, is committed and needs
# no post-clone step.
set -eu

if ! command -v xcodegen >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
fi

cd "$CI_PRIMARY_REPOSITORY_PATH/Spike"
xcodegen generate
