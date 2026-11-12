# Onboarding: the second engineer, from 18 Jan 2027

Written on 12 Nov 2026, at the close of Iteration 2 (I19), for the engineer who joins on 18 Jan 2027 (week 10) and
works with Shamil. It points at the documents rather than repeating them, and says what is
true of the code on `main` at 53f3008. Where this page and a backlog disagree, the backlog's status tables were
checked against the code on 12 Nov and win; where the backlog and the code disagree, the code wins and the backlog
needs a fix.

## What the app is

An iPhone app (iOS 27, Swift 6, SwiftUI) that imports photos from a Sony α7C II over USB-C (PTP through
`ImageCaptureCore`) and over the camera's own Wi-Fi (PTP/IP, our own Swift codec on `Network.framework`, switched on
and joined from the app over Bluetooth LE). It diffs the card against a catalogue, so a file is imported once whatever
route finds it, resumes after a cable pull or a Wi-Fi drop, saves to Photos (a RAW+JPEG pair as one asset) or stages
to iCloud Drive for culling first, and keeps a History of its jobs. The bet is open standards (PTP) over Sony's phone
protocol. No third-party dependencies, no Sony marks in any name or icon.

## Where to start reading, in this order

1. [`README.md`](../README.md): what is where, and the status list.
2. [`AGENTS.md`](../AGENTS.md) (`CLAUDE.md` imports it): the rules below, in full. Read it before the first commit.
3. [`proposal.md`](proposal.md): the architecture, engine design, screens, privacy and testing strategy. An export of
   a live doc, so it is not edited here; where a later decision changed it, the backlogs say so.
4. [`spike-findings.md`](spike-findings.md): what the camera, `ImageCaptureCore` and the radios did in the spike, with
   the measurements and the go/no-go record. [`decision-pack.md`](decision-pack.md): the decisions taken on top of it,
   with their evidence.
5. [`iteration-1-backlog.md`](iteration-1-backlog.md) (wired import) and
   [`iteration-3-4-backlog.md`](iteration-3-4-backlog.md) (Wi-Fi, Bluetooth, background and proximity): acceptance
   criteria and a status table per section, with the pull request and the code behind each row.
6. [`iteration-2-backlog.md`](iteration-2-backlog.md), starting at its "Iteration 2 at close (12 Nov)" section: what
   was built by wave, what CI verifies, what still needs the bench, and the list that is open for Shamil. Sections 1
   to 3 (identity, resume, the fault matrix, with 3.1's commit boundary) are the engine's contract.
7. The bench sheets, [`iteration-2-bench.md`](iteration-2-bench.md) and
   [`iteration-3-4-bench.md`](iteration-3-4-bench.md): checks only the camera and the iPhone can settle, with the log
   line each reads. Nothing in Iteration 2's new scope has been run against the camera yet.
8. [`ci.md`](ci.md): how the apps are built, tested and delivered.

## The rules that bite

- **Attribution.** Commits and pull requests are attributed to Shamil only: author and committer are the identity
  `AGENTS.md` names, with no `Co-Authored-By`, session link or "generated with" line, and no `--no-verify`.
  Run `make hooks` once per clone; `.githooks/` enforces it. Never rewrite existing history.
- **Fixtures** (`Fixtures/a7c2/`) are bytes from the real camera: never edited by hand, and the serial and hardware ID
  are zeroed by `scripts/redact-fixtures.py` (run by `make fixtures`, checked by the pre-commit hook). Never commit
  Wi-Fi passwords, QR payloads, packet captures (`.pcap`, `.pcapng`) or MTP property lists.
- **Docs.** British English (catalogue, colour, behaviour). `proposal.md` and `spike-plan.md` are exports: don't edit
  them. No serials, identifiers, network names, addresses (the camera's 192.168.122.1 is the exception),
  passwords or people in docs.
- **Say what was compiled and run where.** Linux builds and tests only what isn't behind `#if canImport(...)`; the
  app and the Apple-only code are compiled by CI. Don't write "built" for what only CI will build.
- **Conventions.** Apple frameworks only. PTP is little-endian; spec values not yet seen on the α7C II are named or
  commented `unverified`. Imperative commit subjects with a body that says why.

## The codebase map

The layer rule: `AppUI → ImportEngine → {Catalogue, PhotosBridge, CameraTransport} → PTPKit`. The `PTPSimulator`
target depends on `PTPKit` only; its package's `SimulatedLink` target adds `CameraTransport`, and its `IntegrationTests`
drive the real engine. Nothing that ships depends on it: it is a test dependency only. Every package builds and tests
alone, on Linux too, in Swift 6 language mode with strict concurrency; every public type is `Sendable`.

| Package | What it holds |
| --- | --- |
| `PTPKit` | Pure Swift: the PTP and PTP/IP codec (containers, datasets, partial reads and 0x9211 resume, Sony's whole-card session), tested against the camera's fixtures. Decoders throw on bad input and never trap. |
| `BLEKit` | Pure Swift: the camera's Bluetooth parsers (advertisement, status, Wi-Fi credentials, the control characteristic). |
| `CameraTransport` | The `CameraLink` protocol and its links: `USBLink` over `ImageCaptureCore` (MSC and MTP, thumbnails, card free space), `IPLink` over PTP/IP, `StagingFolderLink` (Staging read as a camera); also the Bluetooth hand-off, the Wi-Fi join, recovery and the proximity scan. |
| `Catalogue` | What has been imported, staged, marked, or is in flight: `CatalogueStore` over `InMemoryCatalogue` (Linux) and the SwiftData store (schema V1 to V4, lightweight migrations); `ObjectIdentity`, job records, cull marks, `PendingCommit`. |
| `PhotosBridge` | Destinations: Photos (`PhotosLibraryDestination`, albums, pairs as one asset) and Staging (`StagingFolderDestination`, `FolderPlacer`, iCloud Drive or On My iPhone); `PendingCommit` lookups (`AssetQuery`, `StagedCopyFinder`). |
| `ImportEngine` | One actor that runs a job: diff, queue, download, commit, pause and continue, resume, recovery, job records, the commit boundary and its launch pass, *Import keepers* routes, and `EngineTrace`. |
| `AppUI` | The models and screens: Cameras, Browse, Import, History, the Staging tab with the cull screen and loupe, Settings, the intents, the diagnostics export, wording and the String Catalog; `LiveRoot` composes the app. |
| `PTPSimulator` | A fake camera: `SimulatedCameraLink`, `PTPIPSimulatorServer` and the integration tests, including the fault matrix. |

Beside them:

- `App/` is the iPhone app: `ShutterBridge.xcodeproj` is **hand-written and committed** (Xcode Cloud needs no
  post-clone step), and its `ShutterBridge/` folder is a synchronised folder, so the project file never lists source
  files. The target is the `@main` shim, `AppIntentsPackage.swift`, the asset catalogue and the privacy manifest;
  code goes in a package. `Info.plist` and `ShutterBridge.entitlements` sit outside the folder on purpose.
  `ShutterBridgeUITests/` is the UI-test target. Never replace the project with a generated one; edit `project.pbxproj`
  by hand only with fresh 24-hex object IDs, and say in the PR that CI alone compiled it.
- `Spike/` is the archived spike app (Swift 5 mode on purpose, generated by XcodeGen, `Spike.xcodeproj` never
  committed). `spike-build.yml` still builds it. Nothing from it is carried into the packages.
- `Fixtures/`, `scripts/` (`redact-fixtures.py`, `update-string-catalogue.py`), `.githooks/`, `.devcontainer/`.

## Building and testing

| What | How |
| --- | --- |
| Every package's tests | `make test` (macOS, or Linux with a Swift 6.2+ toolchain), or `swift test` inside one package. `make test-docker` uses the Swift 6.4 image. Run it before every commit that touches `Packages/`. |
| Without a Mac | The dev container (`.devcontainer/`, CI's `swift:6.4-noble` image): `make test` and `make fixtures` work; neither app builds there. |
| The app | Xcode 27 on a Mac: `make app` opens `App/ShutterBridge.xcodeproj`. Cameras never reach the Simulator: anything that talks to one needs a physical iPhone. |
| Pull-request checks | `packages-linux.yml`: every package's tests on Linux. `app.yml` (Xcode 27 runner): the app unsigned for the Simulator and a device, the UI tests, the Photos lookup check, every package's tests in the Simulator, and the entitlements checks. |
| TestFlight | `testflight.yml` ("App to TestFlight"): manual only, in the `testflight` environment, which needs Shamil's approval for each run. It checks the icon and the signed entitlements before uploading. Release notes ([`testflight-what-to-test.md`](testflight-what-to-test.md)) are pasted into App Store Connect by hand. |

If you change the Swift image, change it in `.devcontainer/Dockerfile`, `.github/workflows/packages-linux.yml`, the
`Makefile` and `docs/ci.md` together. Details, secrets and one-time setup are in [`ci.md`](ci.md).

## The engine's invariants, in brief

Each is tested; the backlog sections named hold the evidence.

- **A file is imported once, whatever route finds it** (backlog 1). Identity is file name (ASCII case folded) + capture
  second + size, ignoring USB mode, camera key and folder. A relisting in another time zone finds the same rows
  (`CameraItem.captureTimeZone`). Files without a capture date are left out and counted. A Wi-Fi handle is a hint,
  rechecked by name and size before use.
- **A file's row is its last catalogue write.** The engine writes a pending-commit marker before it calls a
  destination and clears it in the same store save as the file's rows (`beginCommit`, `finishCommit`); a marker that
  can't be written means nothing is committed. A write that fails every try is kept in memory and replayed before
  the next diff (backlog 3.1).
- **The launch pass.** At launch, and before every diff, the engine resolves leftover markers (looking in Photos by
  date and original name, or in the Staging day folder), then resets partial rows whose file is gone
  (`ImportEngine.launchPass()`, `resolvePendingCommits()`, `reconcilePartials()`). A doubtful answer is always "not
  found": a duplicate can be undone, a loss can't. Resolution writes only to the catalogue, never to Photos or Staging.
- **Resume.** Wi-Fi resumes from 16 MiB checkpoints with 0x9211; USB copies the interrupted file again from its start.
  A pull, drop, stall or power-off pauses a job and never fails the file in flight. Partials live in
  `Library/Caches/Imports/Partials/<uuid>/`, pruned after 7 days (which also resets their rows).
- **Pairs are one commit unit** (a Photos asset, or one Staging day folder under one stem); a skipped half leaves the
  other alone.
- **Rejects stay rejected.** A file with a Reject mark (kept by content key, so it outlives its staged copy) is left
  out of *all new*, a date range and a re-queued job; an explicit pick still imports it.
- **Staging and keepers.** A Photos refusal (3311) switches the rest of a job to Staging; a keepers job has no
  fallback and stops for Photos access. Removing staged copies acts only on recorded paths, once confirmed. Nothing is
  ever deleted from the camera: the `CameraLink` contract has no delete call.
- **Every engine event is worded.** `EngineTrace` events become one `engine:` line each in `EngineTraceWording`, at
  error level only for real failures, with no private value in any line (camera keys are logged as per-launch tags).
- **No catalogue write on the main actor.** The engine talks to the store through its actor, and progress is
  monotonic (`ProgressHighWaterTests`).

## Where things are tested

- **Swift Testing** everywhere: tests sit beside each package, `Tests/<Package>Tests/` (PTPSimulator's are
  `PTPSimulatorTests`, `SimulatedLinkTests` and `IntegrationTests`). Pure logic, models, wording and
  the engine's rules run on Linux with fakes (a fake library, `FailingCatalogue`, a recording destination).
- **The fault matrix** (`Packages/PTPSimulator/Tests/IntegrationTests/FaultMatrix*.swift`, about 230 cases in 3 s;
  `swift test --filter FaultMatrix` in that package) runs every transport case against the real engine,
  `InMemoryCatalogue` and the simulators, at 10, 50 and 99 % of a file where an offset applies, and checks five
  points: committed once, bytes match, rows match, the work folder is clean, progress never went backwards. It is the
  evidence for "no duplicates, no loss" (backlog 3). A case the engine fails is fixed in the engine.
- **CI only**: SwiftData and its migrations, Photos, `ImageCaptureCore`, the SwiftUI views, App Intents, the OSLog
  store, the coordinated file operations. `ShutterBridgeUITests` runs History, Settings and the Staging tab in the
  Simulator over a seeded in-memory catalogue (`-UITestFixture`, Debug builds only, built in `AppUI/UITesting/`), and
  `PhotosLookupCheckUITests` runs the Photos lookup against assets the app saves (`-PhotosLookupCheck`).
- **The bench**: everything about the camera's and iOS's real behaviour, on the two bench sheets. A check that fails
  there is recorded as *Fail* with what was seen.

## What is open

The list lives in the backlog, so it has one home: **"Open for Shamil" in the "Iteration 2 at close" section of
[`iteration-2-backlog.md`](iteration-2-backlog.md)**. The ones that touch your first weeks are the unbuilt half of D11
(albums and a paused job across MSC and MTP), the bench results that will move the identity and resume rules (checks 1,
5, 6, 19, 20), and what the first iCloud build shows about staging. Ask Shamil which comes first.
