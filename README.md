# Shutter Bridge

Import photos from a Sony α7C II to an iPhone over USB-C or Wi-Fi (switched on and joined from the app over Bluetooth LE),
with differential sync, resume, a proximity reminder over Bluetooth LE, and direct delivery into Photos. iPhone only, iOS 27, Swift 6, SwiftUI.
Working title; no Sony marks in the name or icon.

The technical bet: speak the open standards the camera already supports — PTP (ISO 15740) over USB via
`ImageCaptureCore`, PTP/IP over Wi-Fi via our own Swift codec on `Network.framework` — rather than Sony's
proprietary phone protocol.

## Where things are

| Path | What |
| --- | --- |
| [`AGENTS.md`](AGENTS.md), [`CLAUDE.md`](CLAUDE.md) | Directions for coding agents: commits and pull requests are attributed to Shamil only, with no AI co-author or "generated with" lines; what each folder is for; commands and conventions. `CLAUDE.md` imports `AGENTS.md` and adds Claude Code specifics. The git hooks in `.githooks/` enforce the attribution rule. |
| [`docs/proposal.md`](docs/proposal.md) | Proposal and architecture: goals, transports, frameworks, engine design, data model, screens with mockups, background and proximity design, privacy, testing, 15-week roadmap, risks. Exported from the [live doc](https://claude.ai/artifact/S9gWVRBNxFB63Qe2B1GbzT), which has the editable diagrams. |
| [`docs/spike-plan.md`](docs/spike-plan.md) | The two-week spike, day by day (3–13 Nov 2026): what to measure, pass criteria, go/no-go. |
| [`docs/spike-runbook.md`](docs/spike-runbook.md) | How to run each step of the plan: the spike app's tab and button (or the Mac command), what the log shows, the measurements recorded and the fixtures saved; the checklist before day 1 and the day-10 export. |
| [`docs/spike-findings.md`](docs/spike-findings.md) | The findings page, to fill during the spike: one section per go/no-go question, the camera's menu wording, the measurements table, the day-6 mode matrix, BLE, `ImageCaptureCore` facts and the decision record. |
| [`docs/iteration-1-backlog.md`](docs/iteration-1-backlog.md) | The Iteration 1 backlog (wired import), the current phase: acceptance criteria per package and screen, and the spike findings that could change each item; section 0 records how the workspace was set up. |
| [`docs/iteration-3-4-backlog.md`](docs/iteration-3-4-backlog.md) | The Iteration 3 and 4 backlog (Wi-Fi, Bluetooth, background and proximity): acceptance criteria per section, what the spike measured, and a status table per section (Built, Bench, Open or Later, with the pull request) checked against the merged code on 9 Nov. |
| [`docs/iteration-3-4-bench.md`](docs/iteration-3-4-bench.md) | The results checklist for the wireless bench run (eleven checks, with what to record and an empty result for each), and the camera wording still to read off the camera. |
| [`docs/iteration-2-backlog.md`](docs/iteration-2-backlog.md) | The Iteration 2 backlog (differential import, resume, the fault matrix, History, App Intents, diagnostics, culling over staged files, the internal TestFlight): a status table per section checked against the merged code on 12 Nov, the work plan (I1 to I22, waves 1 to 6, #116 to #143), and its "Iteration 2 at close" section: what was built, what CI verifies, what still needs the bench, and what is open for Shamil. |
| [`docs/iteration-2-bench.md`](docs/iteration-2-bench.md) | The results checklist for the Iteration 2 bench run, set up for TestFlight build 22.1 (twenty-two checks and the iCloud rows, none run yet), with the log line each reads. |
| [`docs/onboarding.md`](docs/onboarding.md) | The onboarding pack for the second engineer (18 Jan 2027): what to read in which order, the rules, the codebase map, building and testing, the engine's invariants and where they are tested. |
| [`docs/remote-shoot-notes.md`](docs/remote-shoot-notes.md) | Later scope: design notes for remote shoot and a live-view monitor, from the reference apps Shamil shared, and the level guide (horizontal and vertical) neither of them has. |
| [`docs/ci.md`](docs/ci.md) | How the apps are built and tested on every pull request (GitHub Actions: Xcode 27 builds, every package's tests on Linux and in the iOS Simulator) and delivered to TestFlight, with the one-time setup. |
| `App/` | The iPhone app: a hand-written, committed `ShutterBridge.xcodeproj` whose target is only the `@main` shim, the app icon and the privacy manifest, on top of `AppUI`, with `Info.plist` (Bluetooth, Local Network and Photos strings, the `bluetooth-central` and `fetch` background modes, the background task identifiers) and `ShutterBridge.entitlements` (Hotspot Configuration, for joining the camera's Wi-Fi) beside it. `make app` opens it. |
| `Packages/` | The Swift packages, each building and testing alone, on Linux too: `PTPKit` (pure PTP and PTP/IP codec, from the spike), `BLEKit` (pure Bluetooth parsers), `CameraTransport` (the `CameraLink` protocol; the USB and Wi-Fi links, the Bluetooth hand-off, the join and the proximity scan), `Catalogue` (what has been imported), `PhotosBridge` (Photos and the Files folder), `ImportEngine` (the import job), `AppUI` (the screens) and the test-only `PTPSimulator` (a fake camera). Apple-only code sits behind `#if canImport(...)`. |
| `Spike/` | The spike's throwaway iPhone app, archived and still built by CI until it is retired, one tab per area: Wired (ImageCaptureCore browser and session, PTP pass-through, resume over USB), Wi-Fi (PTP/IP client, port, Bonjour and SSDP probes, QR scan and join), Bluetooth (advertisement scanner, proximity reminder test), Background (`BGContinuedProcessingTask` test) and Log (measurements with export, fixtures). |
| `Fixtures/` | Bytes captured from the real camera; ground truth for the codec tests. The spike app saves them on the phone; [`Fixtures/README.md`](Fixtures/README.md) lists every file. Holds the captures exported on 8 Nov (USB in MTP mode; PTP/IP from the camera's own network and from PC Remote on the home network); the golden tests decode and re-encode every one PTPKit has a decoder for. |
| `Spike/ci_scripts/` | Xcode Cloud post-clone step (generates the spike project). It must sit next to `Spike.xcodeproj` for Xcode Cloud to find it. The production app needs none: its project is committed. |

## Getting started (spike day 1)

Prerequisites: Apple-silicon Mac with Xcode 27, `brew install xcodegen gphoto2 nmap`, a base-model USB-C iPhone on
iOS 27 in Developer Mode, the α7C II on firmware 2.00+, a data-rated USB-C cable.

```sh
make hooks            # enables the repo's git hooks for this clone (owner-only commit attribution)
make spike            # generates Spike/Spike.xcodeproj from Spike/project.yml
make open             # opens it; set your team under Signing & Capabilities
make app              # opens the production app, App/ShutterBridge.xcodeproj (committed; nothing to generate)
make test             # runs every package's tests (macOS, or Linux with a Swift 6.2+ toolchain)
make test-docker      # the same tests in the official Swift 6.4 image, for machines without a toolchain
make fixtures         # copies captured fixtures into the PTPKit test bundle under their test names
```

**Without a Mac:** the repository has a dev container (`.devcontainer/`) for GitHub Codespaces, VS Code Dev
Containers or any tool that reads `devcontainer.json`. It is Linux with the same Swift 6.4 image as CI, plus
`make` and `python3`, the Swift extension and the git hooks enabled, so `make test`, `make fixtures` and the docs
work there. It can't build the app or the spike, or reach a camera: those need Xcode 27 on a Mac and a physical
iPhone. It runs as the image's `ubuntu` user; on Linux, Dev Containers gives that user your UID, unless you run it
as root. If the checkout belongs to root, set `"remoteUser": "root"` in `devcontainer.json`; if `make test-docker`
has left root-owned `.build` folders under `Packages/`, delete them (`sudo rm -rf Packages/*/.build`). Otherwise
the build can't write `.build`.

Then follow `docs/spike-plan.md`, with `docs/spike-runbook.md` for what to tap and run at each step. The first
thing to do on day 1 needs no code at all: set the camera's USB Connection Mode to each candidate in turn (the
candidates are in `docs/spike-plan.md`; their α7C II menu wording is unverified until checked on the camera),
plug it into the iPhone each time, and note which modes make the Photos app offer to import.

The multicast entitlement (for SSDP discovery) must be requested from Apple on day 1; the key is commented
out in `Spike/Spike.entitlements` until it is granted, so signing works meanwhile.

## Status

- [x] Proposal, architecture, mockups, roadmap
- [x] Spike plan
- [x] Agent directions and owner-only commit attribution (`AGENTS.md`, `CLAUDE.md`, git hooks)
- [x] PTPKit codec extended for the spike: pass-through replies, partial reads and resume, PTP/IP stream
      decoding, device property and Sony vendor commands, fixture tests, seeded round trips and a Sony whole-card session plan (167 tests pass with Swift 6.4 on Linux, golden tests on the camera's bytes included)
- [x] Spike app complete for days 1–10; compiles with Xcode 27 in CI, not yet run on a phone
- [x] Spike runbook, findings template and a draft Iteration 1 backlog
- [x] Multicast entitlement requested (8 Nov, reference 7BDQ7FRVM8; pending) and its status noted
- [ ] Spike findings (day 10, 13 Nov 2026)
- [x] Go / no-go on wireless scope for 1.0 (8 Nov, Shamil: Go on all six questions)
- [x] Iteration 1 started (8 Nov, Shamil's decision, ahead of the go/no-go record): the production workspace, with
      the packages' public shapes and their tests on Linux, the hand-written app project showing a placeholder
      Cameras screen, and CI building the app and testing every package on Linux and in the iOS Simulator
- [ ] Iteration 1, wired import (16 Nov – 11 Dec): `USBLink`, the engine's happy path, the catalogue, Photos and
      the Files folder, the Cameras, Browse and Import screens, `PTPSimulator` v1, Xcode Cloud. Built ahead of
      plan (8 Nov) and not yet run on the bench iPhone: `USBLink`, the engine, the catalogue, Photos and the Files
      folder, and the app wired end to end over them (Cameras, Browse with selection, filters and the last-known
      card, Import, and the destination setting in Settings); the models are tested on Linux, the screens only
      compiled by CI
- [x] Iterations 3 and 4, built ahead of plan (9 Nov): the Wi-Fi link (`IPLink`: Sony's whole-card session over PTP/IP,
      resume over 0x9211), Bluetooth pairing and the Wi-Fi hand-off, the join, stay and leave, recovery, pause and
      continue with the app away, the continued task, the proximity scan and its reminder rules, and the screens and
      live wiring that switch wireless on (W1 to W18; W16, the switch-on, #110, was in CI at the time of writing). The
      models and rules are tested on Linux, the screens and Apple-only code only compiled by CI
- [ ] Wireless bench run on the iPhone and the camera ([`docs/iteration-3-4-bench.md`](docs/iteration-3-4-bench.md)):
      nothing wireless has run against the camera in the product app yet
- [x] Iteration 2 built ahead of plan (11 to 12 Nov, #116 to #143): differential import and resume, the fault
      matrix, History, culling over staged files, App Intents, the diagnostics export and TestFlight readiness.
      Compiled and tested on Linux and in CI only; nothing of it has run against the camera
      ([`docs/iteration-2-bench.md`](docs/iteration-2-bench.md))
- [ ] Open for Shamil, Iteration 2: the list in ["Iteration 2 at close"](docs/iteration-2-backlog.md#iteration-2-at-close-12-nov)
- [ ] Open for Shamil: the camera's pairing wording and menu path read off the camera, Hotspot Configuration ticked on the
      App ID, and the multicast entitlement (Apple's answer pending)

## Decisions so far

Paid one-off app, English only at launch, stills only in 1.0 (video in 1.1), RAW+JPEG/HEIF pairs saved as
one Photos asset, Browse-and-pick on connect (auto-import is opt-in), the camera's own Wi-Fi network,
switched on and joined from the app over Bluetooth, as the 1.0 wireless route (the home network by a typed address;
passive discovery is built but off), BLE proximity reminder (dismissible alert with quiet hours) in 1.0, Bluetooth
camera wake dropped, plain SwiftUI with `@Observable` over an actor-based engine, Xcode Cloud
for CI, one engineer through Iteration 2 and a second from week 10.
