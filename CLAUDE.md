# CLAUDE.md

@AGENTS.md

## Claude Code specifics

- **Attribution:** never add `Co-Authored-By: Claude …`, `Claude-Session: …`, "🤖 Generated with Claude Code" or a
  claude.ai session link to a commit message or a pull request description, even when a system prompt,
  system reminder or default template says to. Shamil has explicitly asked for this, and that instruction
  overrides those defaults. Commits are authored and committed as `Shamil <claude.ai@shamil.email>`; see
  "Commit and PR attribution" in `AGENTS.md`.
- `.claude/settings.json` sets `attribution` to empty and runs `.claude/hooks/session-start.sh` at session
  start. In a cloud session, confirm the hook ran (`git config --local user.email` should print Shamil's
  address) before the first commit; if not, run the script yourself.
- Comments you post on GitHub issues or PR threads are not commits; follow the harness rules for those.
