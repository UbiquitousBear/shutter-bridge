#!/bin/sh
# Xcode Cloud runs this after cloning, before resolving packages. It generates the spike's .xcodeproj,
# which is git-ignored. The production workspace (after the go/no-go) will be committed and won't need this.
set -eu

if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

cd "$CI_PRIMARY_REPOSITORY_PATH/Spike"
xcodegen generate
