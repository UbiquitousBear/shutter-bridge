#!/bin/sh
# Claude Code SessionStart hook (wired up in .claude/settings.json).
#
# 1. Points this clone at the repo's git hooks (.githooks), which strip AI attribution trailers and refuse
#    commits authored as an AI identity.
# 2. Commits in this repo are attributed to the owner only. Cloud containers ship a global git identity of
#    "Claude <noreply@anthropic.com>"; when the effective identity is an AI one (or unset), set the owner's
#    identity for this repository only. A human's own identity is left alone.
#
# Override the owner identity per machine with SB_GIT_NAME / SB_GIT_EMAIL (e.g. in .claude/settings.local.json
# "env"). Never fails the session: every step is best effort.

repo="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$repo" ] && [ -d "$repo/.git" ] || exit 0
cd "$repo" || exit 0

owner_name="${SB_GIT_NAME:-Shamil}"
owner_email="${SB_GIT_EMAIL:-claude.ai@shamil.email}"

git config core.hooksPath .githooks 2>/dev/null

is_ai_identity() {
    printf '%s\n' "$1" | grep -i -E -q 'anthropic|noreply@anthropic|^claude([[:space:]]|$)|copilot|openai|codex|cursor|gemini|devin|aider'
}

name="$(git config user.name 2>/dev/null)"
email="$(git config user.email 2>/dev/null)"
if [ -z "$name" ] || [ -z "$email" ] || is_ai_identity "$name" || is_ai_identity "$email"; then
    git config --local user.name "$owner_name"
    git config --local user.email "$owner_email"
    echo "session-start: git identity for this repo set to $owner_name <$owner_email>; hooksPath=.githooks"
fi
exit 0
