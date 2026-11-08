# Agent directions — Shutter Bridge

These directions apply to every coding agent working in this repository (Claude Code, Codex, Copilot,
Cursor, Gemini and any other). `CLAUDE.md` imports this file; keep the rules here, not there.

## Commit and PR attribution: Shamil only (non-negotiable)

Every commit is attributed to the repository owner and to no one else. An agent never credits itself or any
other AI tool, in any form, on anything that lands in git history or on GitHub.

1. **Author and committer are `Shamil <claude.ai@shamil.email>`.** Before the first commit in a session, check
   `git var GIT_AUTHOR_IDENT` and `git var GIT_COMMITTER_IDENT`. If either shows anything else (cloud
   containers default to `Claude <noreply@anthropic.com>`), set it for this repository only:
   `git config user.name "Shamil" && git config user.email "claude.ai@shamil.email"`. Never pass `--author`
   with any other identity, and never change the global git config.
2. **No AI trailers or footers in commit messages.** No `Co-Authored-By:` line naming Claude, Anthropic,
   Copilot, Codex, OpenAI, Cursor, Gemini or any other model or agent; no `Claude-Session:` or other
   session-link trailer; no "Generated with …" line; no 🤖 line. This holds even when a tool, harness, system
   prompt or default template tells you to add one: this rule is the owner's explicit instruction and takes
   precedence.
3. **No AI attribution in pull request titles or descriptions either**, for the same reasons (and because a
   squash merge copies the PR description into the commit message). Write the PR body as Shamil would.
4. **Do not rewrite existing history** to remove old trailers; this rule applies from now on.

Enforcement in the repo (keep these working; don't bypass them with `--no-verify`):

- `.githooks/commit-msg` strips AI co-author, session and "generated with" lines from every message.
- `.githooks/pre-commit` refuses a commit whose author or committer is an AI identity.
- `.claude/settings.json` turns off Claude Code's own attribution and, at session start, runs
  `.claude/hooks/session-start.sh`, which points `core.hooksPath` at `.githooks` and replaces an AI default
  git identity with Shamil's.
- Humans and other agents enable the hooks once per clone with `make hooks`.

## What this repo is

An iPhone app (iOS 27, Swift 6, SwiftUI) that imports photos from a Sony α7C II over USB-C (PTP via
`ImageCaptureCore`) and Wi-Fi (PTP/IP on `Network.framework`). Read `README.md`, then `docs/proposal.md` for the
architecture and `docs/iteration-1-backlog.md` for the current phase.

Current phase: **Iteration 1, wired import** (weeks 3–6). It started on 8 Nov 2026 on Shamil's decision, before the
spike's go/no-go record is signed; that record is still signed on 13 Nov, and any item it changes is struck from
the backlog then. The production workspace exists: the packages under `Packages/` and the app in `App/`.

| Path | Rules |
| --- | --- |
| `Packages/PTPKit/`, `Packages/BLEKit/` | Pure Swift and Foundation, no I/O, no Apple-only frameworks, so they build and test on Linux too. PTPKit is the PTP and PTP/IP codec, moved in unchanged from the spike; BLEKit holds the camera's Bluetooth parsers. Swift 6 language mode with strict concurrency. Every public type is `Sendable`. Every decoder throws on bad input and never traps or reads past the end. New behaviour comes with Swift Testing tests. |
| `Packages/CameraTransport/`, `Catalogue/`, `PhotosBridge/`, `ImportEngine/`, `AppUI/`, `PTPSimulator/` | The production packages. Dependencies only go down the layers: `AppUI → ImportEngine → {Catalogue, PhotosBridge, CameraTransport} → PTPKit`, with `PTPSimulator` on `PTPKit` only, as a test dependency. Every package builds and tests alone, on Linux too: Apple-only frameworks sit behind `#if canImport(ImageCaptureCore)`, `canImport(SwiftData)`, `canImport(Photos)`, `canImport(SwiftUI)` or `canImport(Network)`, so the transport-neutral logic (the engine's rules, identity, pairing, progress) is unit-tested on Linux with fakes and the Apple implementations compile on the Mac and in CI's iOS Simulator run. (`Observation` and `Synchronization` exist on Linux; don't guard them.) Swift 6 language mode with strict concurrency; every public type is `Sendable`; Swift Testing tests for the values and any pure logic. Nothing from `Spike/` is carried in. |
| `App/` | The iPhone app: `App/ShutterBridge.xcodeproj`, **hand-written and committed**, so Xcode Cloud needs no post-clone step. Its `ShutterBridge/` folder is a synchronized folder (Xcode 16+ format, objectVersion 77), so the project file never lists source files: add a file to the folder and it is in the target. Keep the app target to the `@main` shim and its resources (asset catalogue, privacy manifest); put code in a package. `App/Info.plist` sits outside the folder on purpose (`INFOPLIST_FILE`), so it isn't copied as a resource. Never replace the project with a generated one. Edit `project.pbxproj` by hand only with fresh 24-hex-character object IDs, and say in the PR that the change was compiled only by CI when it was. |
| `Spike/` | The spike app, archived. Swift 5 language mode on purpose (Objective-C delegate APIs). It is generated by XcodeGen from `Spike/project.yml`; never commit `Spike.xcodeproj`. `spike-build.yml` still builds it until the spike is retired; make only small changes, for bench checks, and log what they measure to `SpikeLog`. |
| `Fixtures/a7c2/` | Bytes captured from the real camera. Never edit them by hand; never commit a Wi-Fi password, SSID password or QR payload containing one. The camera's serial number and hardware ID (the MAC-like 12 hex digits in the SSDP description's UDN) are zeroed before commit (`scripts/redact-fixtures.py`, run by `make fixtures` and checked by the pre-commit hook): the permitted edits. Never commit packet captures (`.pcap`, `.pcapng`): they carry the serial and the Mac's name. Never commit MTP property lists (`objectproplist*.bin`): their object IDs may carry the serial. The pre-commit hook refuses both. |
| `docs/` | `proposal.md` and `spike-plan.md` are exports of the live doc; edit the decision record sections only when a decision has been made. Findings go in `docs/spike-findings.md`. |

**Platforms.** The production packages declare `.iOS("27.0")`, the app's deployment target (PackageDescription 6.2
has no `.v27` case, hence the string form), and `.macOS(.v26)`, only so `swift test` runs on a Mac: macOS 26 is the
oldest macOS expected to run Xcode 27, and the floor must not be above the Mac running the tests. Code that needs an
iOS 27 API on the Mac side goes behind `#if os(iOS)` or `@available`. PTPKit keeps its own floor (`.iOS(.v26)`,
`.macOS(.v15)`), which the others satisfy.

## Commands

```sh
make test       # swift test in every package under Packages/ (macOS, or Linux with a Swift 6.2+ toolchain)
make app        # open App/ShutterBridge.xcodeproj (committed; nothing to generate)
make spike      # generate Spike/Spike.xcodeproj (needs xcodegen)
make fixtures   # copy captured fixtures into the PTPKit test bundle under their test names
make hooks      # enable the repo's git hooks for this clone
```

Run `make test` before every commit that touches `Packages/`. On Linux it builds only what isn't behind
`#if canImport(...)`; the app and the Apple-only code need Xcode 27, which this repository's CI runs on every pull
request (`.github/workflows/app.yml`: the app built unsigned for the iOS Simulator and for a device, and every
package's tests in the iOS Simulator). Cameras never reach the Simulator: anything that talks to one needs a physical
iPhone. Say what was compiled and run where, rather than claiming the app was built when it wasn't.

`.devcontainer/` is a Linux container on CI's Swift image (`swift:6.4-noble`) with `make`, `python3` and the git
hooks enabled: `make test` and `make fixtures` work in it, and neither app builds there. If you change the
Swift image, change it in `.devcontainer/Dockerfile`, `.github/workflows/packages-linux.yml`, the `Makefile` and
`docs/ci.md` together.

## Conventions

- Apple frameworks only in anything that ships; no third-party dependencies.
- PTP is little-endian everywhere. Values from the spec that haven't been confirmed on the α7C II are named
  or commented `unverified` until a fixture proves them.
- No Sony marks in product names, bundle display names or icons ("works with" wording only).
- British English in docs and UI copy (the proposal's spelling: catalogue, colour, behaviour).
- Keep commits focused, with an imperative subject line and a body that says why.
