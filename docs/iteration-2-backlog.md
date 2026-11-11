# Iteration 2 backlog: differential, resume, History and culling

> **Written on 11 Nov 2026, when Shamil gave the go-ahead to begin Iteration 2 ahead of its planned weeks** (as Iteration 1 began early on 8 Nov). Written from [proposal.md](proposal.md) ("Development iterations", "Import engine design", "Testing strategy", "UX and screens"), [decision-pack.md](decision-pack.md) (items 3.3, 3.6, 3.21 and 3.22), [iteration-1-backlog.md](iteration-1-backlog.md), [iteration-3-4-backlog.md](iteration-3-4-backlog.md), [spike-findings.md](spike-findings.md), and a read of `main` at f7a4f9e (#115). A great deal of what the proposal gives Iteration 2 was built ahead of it in Iteration 1 (#81 to #87) and in the wireless plan (W1 to W20, #89 to #112): the content-key diff, partial rows with 16 MiB checkpoints, 0x9211 resume, the recovery coordinator and most of the simulator's hooks. Every such item below is marked **Built** with its pull request and code, so nothing is planned twice; the real work is the rest of the fault matrix and its "no duplicates, no loss" harness, RAW+JPEG pairing in the engine, History, App Intents, the diagnostics export, culling and the internal TestFlight. Shamil's decisions this backlog rests on are listed below. **The 11 Nov staging decisions** (imports can be staged; culling works from the staged files; keepers go to Photos and the staged copies are then removed) are recorded in [decision-pack.md](decision-pack.md), *Choices decided by Shamil on 11 Nov* (and item 3.23), and in [iteration-1-backlog.md](iteration-1-backlog.md), section 5, *Staging, in place of the Files destination*, with what was built: PhotosBridge's staging destination and `FolderPlacer`, Catalogue schema V3 with a separate *staged* fact, ImportEngine stage jobs, and Browse's Import menu, badges and Settings. This backlog treats staging as landed before any culling work. Every number is a spike measurement with its hedges ("one run", "MTP only"), and an item says so where nothing was measured. `proposal.md` is an export of the live doc and isn't edited here; carrying decision-pack Part 3 and the staging decisions into it is Shamil's.

Iteration 2 is weeks 7–9: 14–18 Dec 2026, then, after the holiday weeks (21 Dec – 1 Jan, not counted), 4–15 Jan 2027, Shamil alone, ending at the internal TestFlight on 15 Jan. From [proposal.md](proposal.md), "Development iterations":

- **Builds:** identity and diff rules; resume offsets and `.part` files; the fault matrix in the simulator; the History screen; App Intents; diagnostics export. **Internal TestFlight.** Added by decision-pack 3.21 B (Shamil, 8 Nov): manual culling (a full-screen loupe, Keep / Reject, optional stars, previews fetched ahead, *Import keepers*, marks kept in the catalogue by a planned migration; nothing is ever deleted from the card). Changed by the 11 Nov decisions: culling works from the **staged** files, *Import keepers* sends the keepers to Photos, and the staged copies (keepers and rejects) are then removed from Staging.
- **Exit criteria:** every fault-matrix case recovers without duplicates or loss; "re-plugging after a pull resumes within 2 s". Culling adds no exit criterion (decision-pack 3.21: whether it gains a preview-time target is left to Shamil once the time is measured). The second criterion can't be met over USB as written (below); decision-pack 3.6 proposes a replacement; D1 is decided (Shamil, 11 Nov): 3.6's wording for USB, plus a Wi-Fi target of resuming from the checkpoint within 5 s of the session reopening.
- **Definition of done** (proposal, "Testing strategy"): all PR suites green, the hardware plan green on the current camera firmware, no new `OSLog` errors in a 200-file import, budget table met.

**What the spike, the decisions and the work built ahead change** (each section gives the evidence):

- **"Resumes within 2 s" can't be met over USB.** Nothing answers until `ImageCaptureCore`'s catalogue is done: 7–12 s in MSC, 65–123 s in MTP for 391–825 files. After a replug the interrupted file is copied again from its start (decision 7; an ARW restarts in about 1 s at 40 MB/s). Decision-pack 3.6 proposes "after a replug the import carries on as soon as the card is listed again, and the interrupted file is copied again from its start". Over Wi-Fi a PTP/IP session reopened in about 2.5 s and 2.9 s (one run each), so a Wi-Fi time target is possible (D1).
- **Resume offsets are built for Wi-Fi, and USB has none by decision.** W4, W7, W8 and W14 built partial rows, checkpoints at each 16 MiB crossing, 0x9211 resume in 4 MiB chunks and recovery (section 2). The proposal's `Caches/Imports/<serial>/<filename>.part` became `tmp/Imports/Partials/<uuid>/<camera filename>` with a path stored relative to that folder; this backlog moves it to Caches (without the serial) and adds reconciliation, rather than replanning resume.
- **Identity is decided** (Shamil, 8 Nov): "already imported" is file name + capture time (to the second) + size, whatever the USB mode, camera key or folder (#87). What is left is bench confirmation, the capture zone, files without a date, and two choices for Shamil (section 1).
- **"Photos permission revoked mid-job" no longer stops the job:** decision 9 switches the rest of the job to Files (built, `photosDenialMidImportSwitchesToFiles`). Staging replaces the Files destination, so the staging branch moves that fallback, and the matrix asserts whatever it lands as: the rest of the job goes to the fallback, with nothing lost or saved twice (section 3).
- **RAW+JPEG pairs aren't wired into the engine.** `commitUnit(for:)` returns `.single(file)` (`ImportEngine+File.swift`), so today each ARW and each JPG becomes its own Photos asset, against Iteration 1's "correct dates and pairs". It is a prerequisite for *Import keepers* and goes first after staging lands (section 7, I6).
- **History has no data yet.** The `ImportJob` model has existed since V1 and nothing writes it; History needs fields it lacks, so it takes a schema version, planned with the cull marks (section 8).
- **App Intents meet the transports' limits:** a Wi-Fi join needs the app in front, and a USB count needs the full catalogue (up to about 2 minutes in MTP). So "Import new photos" opens the app, and "How many new photos" answers from the last-known card (section 5, D7).
- **Naming.** In this backlog *Staging* (capital S) is the person's folder in iCloud Drive or On My iPhone. The engine's temporary folder, `stagingDirectory` in the code, is called the *engine's work folder* here to keep the two apart.

**Not in this iteration:** video (1.1); a continued task over USB (decision 1); the Live Activity and Lock Screen widget (Iteration 4, section 13 of the wireless plan); auto-import on connect (Iteration 4, section 14); USB byte-range resume (decision 7; 0x101B works in MTP but isn't used); the home network as a route, so "reconnect at a different address" is a simulator-only case (Iteration 3, section 10, *Later*); "verify imports against Photos" (a proposal Settings row with no iteration); a "Stage and import" option and "Move to iCloud Drive" (staging research, later); XMP sidecars for ratings (later, D4); iCloud sync of the catalogue (after 1.0, so marks don't follow staged files to another device); culling with on-device models, which is a short spike during Iterations 2–3 on Shamil's own photos, outside the exit criteria, with the feature built for 1.1 (section 7.8); the free-space pre-check, the iCloud upload status and reconciling staged files deleted in Files, which are the staging branch's hardening work (its PR 7), not repeated here. Nothing from `Spike/` is carried in.

## Decisions this backlog rests on

| Decision | By Shamil | Shapes |
| --- | --- | --- |
| 1. USB stays in front | 7 Nov: the import keeps the screen on; the engine pauses on *did suspend* (30 s after the app leaves) and continues on return. | 2, 3, 5 |
| 4. Pause, continue, stall | 7 Nov: expiry is normal; a stall pauses and retries; "failed" only for real errors with limited retries; a cable pull pauses without failing the file in flight; progress in bytes. | 2, 3 |
| 7. Wired mode and resume | 7 Nov: MSC and MTP, one import path (`requestDownloadFile`); after a replug the interrupted file is copied again from its start. MSC resume dropped (4 Nov). | 1, 2, 3 |
| 9. Photos access | 7 Nov: read/write with Limited Access accepted; files staged complete-until-first-unlock; album by stored identifier; a Files path when Photos is denied (8 Nov: a destination setting; 11 Nov: staging replaces Files). | 3, 7 |
| "Already imported" | 8 Nov, after the 17.1 bench run: name + capture time (to the second) + size, ignoring mode, camera key and folder; accepted risk: two cameras with the same name, second and size count as one. ASCII case folding awaits confirmation (D13). | 1, 3, 7 |
| Manual culling | 8 Nov (decision-pack 3.21 B): loupe, Keep / Reject, optional stars, previews fetched ahead, *Import keepers*, marks in the catalogue by a planned migration; nothing deleted from the card. | 7, 8 |
| Model culling | 8 Nov (3.21 C): a short spike during Iterations 2–3, built for 1.1, suggestions only. | 7.8 |
| Staging | 11 Nov (recorded in [decision-pack.md](decision-pack.md), *Choices decided by Shamil on 11 Nov*): Browse's Import button offers *Import to Photos* or *Stage*, remembering the last choice; staged files go to iCloud Drive › Shutter Bridge › Staging/<camera>/<capture day>/, or On My iPhone › Shutter Bridge › Staging when iCloud isn't available; staging replaces the Files destination; a *Staged* badge; *Select all new* skips staged and imported files; culling works from the staged files; after culling the keepers go to Photos and the staged copies, keepers and rejects, are removed from Staging; nothing is ever deleted from the camera. | 1, 3, 4, 7, 8 |
| Go / no-go and dates | 8 Nov: Go on all six questions; the internal TestFlight on 15 Jan 2027 stands. | 9 |
| Wi-Fi | 7–10 Nov: one download at a time on Wi-Fi; the continued task and the pause notification for Wi-Fi (built, W13); Browse over Wi-Fi reconnects only on *Reconnect* or *Try Again* (10 Nov). | 2, 3, 5 |

## Status of each item

Each section starts with a status table, one row per requirement, checked on 11 Nov against `main` at f7a4f9e. Nothing in Iteration 2's new scope has run against the camera, so anything that depends on the camera's or iOS's behaviour is *Bench*.

| Status | Means |
| --- | --- |
| **Built** | Merged on `main` and tested on Linux or in CI's iOS Simulator run; the pull request and the code are named. |
| **Partial** | Some of it is built (named); the rest is a work item (named). |
| **To do** | Nothing built; the work item that builds it is named. |
| **Bench** | Built, or about to be, but only the camera or the iPhone's real iOS can prove it; the bench sheet (I5) holds the check. |
| **Open** | Waiting on a decision or an action; the note says who (decisions are in *Decisions for Shamil*). |
| **Staging** | Built by the staging branch, not by this iteration; listed so nothing is done twice. |

Where tests run: **Linux** means `swift test` on CI's `swift:6.4-noble` image and in the dev container (`make test`). **CI only** means code behind `#if canImport(...)` (SwiftData, Photos, ImageCaptureCore, SwiftUI, AppIntents, OSLog's store) that only `app.yml`'s Xcode 27 job compiles and tests in the iOS Simulator. **Bench** means the bench iPhone with the camera.

# Part 1: the proposal's Iteration 2

## 1. Identity and diff rules

| Requirement | Status | Note |
| --- | --- | --- |
| Rows keep the full identity (camera, folder, filename, capture date, size) | **Built** | #83, #87: `ObjectIdentity`, `storageKey` `v1\|camera\|folder\|filename\|date\|size` (pinned); `upsert` unique by full identity, enforced by the store's actor, not the schema (CloudKit-compatible). |
| "Already imported" by name + capture second + size | **Built** | #87: `ObjectIdentity.ContentKey`, `ContentMatch.states(of:among:)` (furthest along: imported > partial > skipped > new) in both stores; `CatalogueStore.states(of:)` is both the engine's diff and Browse's badge; `CameraItem.identity(camera:timeZone:)` is public. |
| Inside a job, files matched by content | **Built** | #87: `Job.entry(sameContentAs:)`: a re-plug that lists folders differently, `append` skipping what is in the job or imported, one file in two folders queued once with a trace (`ContentMatchTests`, 9 tests). |
| Diff classes new / partial / imported / skipped; new and partial queued | **Built** | #81, #98: `ImportSelection` (`allNew`, `dateRange`, `items`); a later job adopts a `.partial` row's file (W7). |
| Wi-Fi handles are hints, not identities | **Built** | W6 #96, W8 #100: `IPLink.list(reusing:)` with `SonyHandleSet.unseen`; `bytes()` and `info(of:)` recheck name and size and refuse a stale handle as `itemNotFound`. |
| *Staged* as a separate fact; *Select all new* skips staged and imported | **Staging** | Catalogue V3 `markStaged` / `clearStaged` / `stagedStates`, matched by content key; Browse's badges and selection. |
| MSC and MTP report the same capture second and size for one file | **Bench** | The 8 Nov rule depends on it. MTP matched `GetObjectInfo` for one ARW and one JPG (1 Nov); MSC not compared. The listing's bench log line already gives the three newest files' names, times and sizes per mode (iteration-1-backlog.md, section 4). If they differ, Shamil chooses a tolerance or another date source. |
| Names fold ASCII case only | **Open** | Shamil (D13). An implementation choice, not part of the 8 Nov rule. |
| `CameraItem` carries the zone its dates were made in | **To do** | I14. Today `CaptureDate` is wall-clock with the zone fixed per job (iteration-1-backlog.md, section 0, *Provisional*). |
| Files without a capture date | **Open**, then I14 | Shamil (D10). The engine skips them (`noCaptureDate`) and Browse can't select them. |
| MTP `PersistentUniqueObjectIdentifier` (0xDC41) | **Open** | Shamil (D9); recommended dropped. Only the code constant exists (`PTPCodes.swift`). |
| Albums, Staging folders and continuing a job across MSC and MTP; two bodies with one name | **Open** | Shamil (D11). Grouping still uses the camera key, so one camera's MSC and MTP imports go to two albums and folders, and a job paused in one mode doesn't continue in the other. |
| "Forget imports" per camera | **To do** | Store call in I7, History row in I10. |
| A content-key index | **Later** | Only if a slow diff is measured; `states(of:)` fetches by size in chunks of 500. Reserved as V5 (section 8). |
| "Verify against Photos" (deleted assets) | **Later** | No iteration in the proposal. A file deleted from Photos stays imported unless the person uses *Forget imports*. |

Acceptance criteria:

- **A file is imported once, whatever route finds it.** The same file seen in MSC, in MTP, over Wi-Fi, under another camera key or in another folder reads as imported, partial or skipped by content alone (built; `rowsOfOneFileUnderTwoCamerasBothCountAndNeitherIsLost`, `twoCamerasWithTheSameNameSecondAndSizeCountAsOne`, `rowsWrittenByBuild17_1AreFoundByContent`). Tested on Linux against `InMemoryCatalogue`; the SwiftData side in CI only.
- **A relisting in another time zone finds the same files.** `CameraItem` carries either the zone its `Date`s were made in or the camera's raw `YYYYMMDDTHHMMSS`, and `identity(camera:timeZone:)` uses it, so a card listed in London and relisted after a flight still matches its rows to the second. Test (Linux): list in one zone, import, relist the same `ScriptedCard` in a zone 9 hours away, and *Select all new* picks nothing (I14).
- **Files without a capture date get the outcome D10 chooses.** With the recommended choice they stay out of the import and the Import screen says how many were left out and why, and Browse's existing dimmed state stays (I14).
- **Staged files read by content too.** A file staged in MSC reads as staged in MTP and over Wi-Fi (the staging branch's contract tests; this iteration's matrix repeats it as a case, section 3).
- **Bench:** the MSC and MTP capture second and size for the same three files (I5).

Could change with: the bench comparison (a tolerance needs a range query, which a content key can't express); D9 (a persistent MTP identifier would join the identity for new objects only, at about 385 ms each); D11.

## 2. Resume offsets and partial files

| Requirement | Status | Note |
| --- | --- | --- |
| Partial rows with a resume offset and a temporary file | **Built** | W4 #92: `markPartial(_:format:tempURL:offset:)` never undoes `.imported`, refuses an offset past the end and an absolute path; `partialFile(in:)` resolves it; an `.imported` upsert clears both. Columns since V1. |
| Checkpoints at each 16 MiB crossing, on interruption and on flush | **Built** | W7 #98: `PTPPartialRead.crossesCheckpoint`, `flushCheckpoints()`. |
| Resume partial files first, after checking the object still exists and its size matches; else from zero | **Built** | W7 #98: the engine waits for the previous call to end, checks the file on disk holds the offset, asks `info(of:)` for name and size; a mismatch drops the partial, relists and copies from 0. |
| Wi-Fi byte resume | **Built**, **Bench** | W8 #100: `IPLink` resumes with 0x9211 in 4 MiB chunks; a refused first read falls back to GetObject into the same file. Bench checks 8 and 9 of [iteration-3-4-bench.md](iteration-3-4-bench.md). |
| Recovery after a session or card loss | **Built** | W14 #106: `WiFiRecoveryCoordinator`, `reconnect(_:to:knownItems:route:keepingExpiry:)`. |
| USB: the interrupted file copied again from its start | **Built** | #81: `.usb` capabilities say `resumesPartialFiles: false`; the partial is deleted; `cablePullPausesAndTheInterruptedFileIsCopiedAgain`. On replug `ImportModel.cameraConnected()` reconnects the job by camera key. |
| Queue edits mid-transfer: add appends, remove cancels and deletes the temporary file | **Built** | #81: `append(_:)`, `cancelRemovesTemporaryFiles`. |
| Old partials pruned | **Built** | W7 #98: at launch, folders not written for 7 days (`ImportPolicy.partialRetention`). |
| Partials kept somewhere iOS doesn't empty while the app is suspended | **Built** (root CI only) | I13: the app's work folder is `ImportEngine.cachesWorkFolder` (`Library/Caches/Imports`, chosen in `LiveRoot`), partials in `Partials/<uuid>/<camera file name>` with rows relative to it; `ImportEngine.movePartials(from:to:)` brings an earlier build's `tmp/Imports` partials in. `PartialsAndSessionsTests.aPartialUnderTheWorkFolderResolvesAfterTheContainerMoves`. |
| `.partial` rows whose file is gone are reset proactively | **Built** | I13: `ImportEngine.reconcilePartials()` at launch (after the prune) and before every job's diff, over Catalogue's `partialRecords()` and `resetPartial(_:ifTempURL:offset:)` (both stores; SwiftData's `partialRecords` CI only). `aPurgedPartialIsResetBeforeTheNextDiffAndCopiedFromZero`, `theLaunchPassResetsRowsWhoseFilesArePrunedMissingOrShort`. |
| Exit 2: "resumes within 2 s" | **Open** | Shamil (D1). Can't be met over USB as written. |
| A late `.sessionLost` from the old session told apart from a new loss after a reconnect on the same link | **Built** | I13: `CameraLinkEvent.sessionLost(generation:)` and `CameraLink.sessionGeneration` (`IPLink`, `SimulatedCameraLink`); the engine ignores a loss of a session a `reconnect` replaced (`lateSessionLossIgnored`). `aLateLossOfAReplacedSessionIsIgnored`, `EngineResumeAgainstSimulatorTests.aLateLossFromAReplacedSessionDoesNotPauseTheNewOne`. |
| Bench: the first file after a *Continue* compared byte for byte; whether *did suspend* reaches the engine without a continued task; the 30 s stall limit against real stalls; the screen staying on | **Bench** | Iteration 1's open checks (iteration-1-backlog.md, section 3). The fault-matrix exit relies on them. I5. |
| USB byte resume (0x101B in MTP) | **Later** | Decision 7. Measured working once (a cable pull at 47 %, SHA-256 matched), 10.8 % slower than `requestDownload`. |

Acceptance criteria:

- **A partial file survives what iOS does to an app between launches.** Partials live under `Library/Caches/Imports/Partials/<uuid>/<camera filename>` (the proposal's Caches, without the serial, which never goes in a path), still stored relative to the work folder in the row, so a container move on update keeps working. The `<uuid>` folder marks a partial; no `.part` extension is needed. Test (Linux): the engine made with a Caches-like root writes partials there and resolves stored paths against it (I13).
- **A missing partial resets its row before the diff.** At launch, after pruning, every `.partial` row whose file is missing or shorter than its offset goes back to offset 0 with no temporary file (a catalogue call that keeps the row `.partial`), and the next job copies it from 0. Test (Linux): delete a partial between two jobs; the second job starts it from 0, writes no wrong bytes and reports no failure (I13).
- **One 7-day rule for both:** a partial folder pruned by age also resets its row.
- **A late loss from a replaced session doesn't pause the new one.** Each reconnect carries a generation; a `.sessionLost` or failure stamped with an older generation is ignored. Test (Linux): a `SimulatedCameraLink` that reports the old session's loss after `loseSessionAndReopen()`; the job keeps running (I13).
- **Exit 2 is met in the wording D1 settles.** With the recommended wording: over USB, after a replug the job carries on with no tap as soon as the card is listed again, and the interrupted file is copied from its start; over Wi-Fi, after a drop and a reopen the file in flight resumes from its last checkpoint within 5 s of the session reopening. Linux tests time it on the engine's manual clock (I15); the bench sheet times it on the camera, with the log lines I8 adds (job resumed after a reconnect, the first byte after it).

Could change with: D1; a bench result that contradicts decisions 1, 4 or 7; Apple changing what iOS empties (Caches can also be emptied under storage pressure, which the reset above covers).

## 3. The fault matrix in the simulator

The proposal: "cable pulled at 10 %, 50 %, 99 % of a file; Wi-Fi drop then reconnect with the same and a different IP; card swapped between sessions (handles reused for different files); phone storage full mid-job; Photos permission revoked mid-job; camera powers off from battery; two cameras with the same friendly name", and, for the integration suite, "drop mid-transfer, slow link, duplicate filenames, ObjectAdded mid-job". Comments in `PTPResponder` and `SimulatedCameraLink` already say these are Iteration 2's.

**The harness (I22, over the simulator hooks I1 adds).** One table-driven suite in `PTPSimulator`'s integration tests runs every case below against each link flavour that applies (USB: `SimulatedCameraLink` with `.usb` capabilities, 1 and 2 in flight, as MSC and as MTP keying; Wi-Fi: `SimulatedCameraLink` with resuming capabilities, and, for the cases where the wire matters, the real `IPLink` against `PTPIPSimulatorServer`), at 10 %, 50 % and 99 % of a file where an offset applies, with the real `ImportEngine`, `InMemoryCatalogue` and a destination fake that records every committed unit. After each case recovers, it asserts **no duplicates and no loss**:

1. every selected file is either committed exactly once (one unit in the destination per content key) or reported as skipped or failed with its reason; none is silently missing;
2. the bytes committed equal the scripted card's bytes for that file;
3. the catalogue holds one `.imported` row per committed file and none for a file not committed; `.partial` rows exist only for files the case leaves resumable;
4. the engine's work folder holds nothing but kept partials once the job ends (the harness lists it from the engine's trace sink at the moment each job reads as finished, before the driver can remove the job's folder, as well as after the job and its abandoned calls have ended);
5. progress never went backwards, and the outcome class (retry now, retry on reconnect, skip this file, stop the job) is the one the error taxonomy gives.

| Case | USB | Wi-Fi | Status | Note |
| --- | --- | --- | --- | --- |
| Cable pulled (removal) mid-file | 10 / 50 / 99 % | n/a | **Built** | One offset in `aRemovalMidFileWaitsAndTheReplugCopiesItAgainFromItsStart`, `cablePullPausesAndTheInterruptedFileIsCopiedAgain`; the harness (I22, `FaultMatrixCutTests.cablePulledMidFile`) runs the three offsets, MTP and MSC keying, 1 and 2 in flight, for an import and a stage job. |
| Wi-Fi drop, reconnect at the same address | n/a | 10 / 50 / 99 % | **Built** | Built at 54–55 %: `aDownloadCutAt54PercentResumesWith0x9211AndMatches`, `EngineResumeAgainstSimulatorTests`; the harness runs the three offsets through `SimulatedCameraLink` (`FaultMatrixCutTests.wifiDropMidFile`) and through the real `IPLink` (`FaultMatrixWireTests.dropMidFile`). |
| Wi-Fi reconnect at a different address | n/a | simulator only | **Built** | I1's hooks, run by the harness at the three offsets, to another port and to another address: `FaultMatrixCutTests.wifiReconnectAtADifferentAddress` (the link's location provider) and `FaultMatrixWireTests.reconnectAtADifferentAddress` (a new `IPLink` to where the camera moved; a `PTPIPSimulatorServer` restart is Network.framework only and stays CI's). The camera's own network has a fixed gateway; the home route is *Later*. |
| Card swapped between sessions | names reused, other files | handles reused for other files | **Built** | Wi-Fi at link level (`aHandleThatNowNamesAnotherFileIsCaughtBeforeAnythingIsWritten`); the harness runs both through the engine (`FaultMatrixCaseTests.usbCardSwappedWithReusedNames`, `wifiCardSwappedWithReusedHandles`). **Known issue (I15):** on Wi-Fi the skipped old file leaves its partial file and `.partial` row behind until the 7-day prune. |
| Phone storage full mid-job | yes | yes | **Built** | `phoneStorageFullStopsTheJobAndKeepsWhatWasImported`; the harness runs a failing download and a failing commit on both carriers for an import and a stage job (`FaultMatrixCaseTests.storageFullDuringADownload`, `storageFullAtTheCommit`), then the next job finishing the rest. **Known issue (I15):** a full phone stops a resumed Wi-Fi read and the engine deletes the partial the backlog says is kept (the row stays `.partial`), so the next job copies from 0 (`storageFullWhenAWiFiFileResumes`). |
| Photos access revoked mid-job | yes | yes | **Built** | `photosDenialMidImportSwitchesToFiles` (engine level, 1 and 2 in flight); the harness asserts the new route end to end on USB and Wi-Fi, 1 and 2 in flight: first file in Photos, the rest staged, `.staging(.photosDenied, …)`, no duplicates (`FaultMatrixCaseTests.photosAccessRevoked`). |
| Camera powers off (battery) | removal with no replug | session lost with no return | **Built** | I1's power-off hook, run by `FaultMatrixCutTests.powerOffOverUSB` and `powerOffOverWiFi`: the job stays paused (not failed) an hour on the manual clock, the Wi-Fi partial row and file are kept, and the reconnect finishes the job; a partial six days old is kept and continued by a relaunched engine (`killedAfterAWiFiDrop`). |
| Two cameras with the same name | yes | yes | **Built** | Catalogue (`twoCamerasWithTheSameNameSecondAndSizeCountAsOne`) and the harness at engine level: two bodies with one display name, different keys and cards; different files both imported, the same name + second + size counted once (the accepted risk), `FaultMatrixCaseTests.twoCamerasWithOneName`. Folder and album sharing follow D11. |
| Slow link | yes | yes | **Built** | I1's throttle; `FaultMatrixCaseTests.slowLinkNeverStalls`: a 40 KB file at 1 KiB a second (40 s on the manual clock) never trips the 30 s stall. |
| Duplicate file names | one name in two folders; counter wrap | same | **Built** | `aListingWithOneFileInTwoFoldersQueuesItOnce`; `filenameReusedAfterTheCounterWrapsIsANewFile`. Repeated in the harness (`oneNameInTwoFolders`, `counterWrap`, `reusedNameNextToAnImportedFile`). |
| ObjectAdded mid-job | n/a (MSC and MTP send none) | yes | **Built** | `FaultMatrixCaseTests.frameShotMidJob` (not added to the running job, new in the next listing) and `frameShotMidJobAndAppended` (appended: copied once). |
| Stall, then progress | yes | yes | **Built** | `aStallPausesThenRetriesTheFile`, `repeatedStallsWaitForThePerson`. Repeated in the harness (`stallThenProgress`, with the abandoned first call released late: nothing is committed twice). |
| *Did suspend* mid-file | yes | n/a | **Built** | `didSuspendPausesUntilTheAppReturns`. |
| Short file | yes | yes | **Built** | `aShortFileIsCaughtBySizeAndFetchedAgain`; repeated in the harness (`shortFile`). |
| App killed mid-job, relaunched | yes | yes | **Partial** | The download phase is built (I22): a relaunched engine continues a Wi-Fi file from the catalogue's partial row and copies a USB file from 0 (`FaultMatrixCutTests.killedAfterAWiFiDrop`, `killedMidDownloadOverUSB`, `killedMidDownloadOverWiFi`). I15 for the commit boundary (below). |
| Killed between the Photos save and the catalogue write | yes | yes | **To do** | I15, with the pending-commit marker of section 3.1 (I9 writes it). The asset exists, the row doesn't, and the next import saves it again. The stage-job equivalent: killed between placing the file in Staging and the `markStaged` write. |
| Catalogue write fails after the save, every retry used | yes | yes | **To do** | I15. `commitAndRecord` returns `rowWritten: false` and the job ends `.catalogueUnavailable` with the asset in Photos and no row, so the next import saves it again; the test Support folder's `FailingCatalogue` scripts it. The stage-job equivalent: the file placed in Staging, then the `markStaged` write lost. Resolved as section 3.1 designs. |
| Stage-job cases: iCloud lost mid-job; on-iPhone fallback; storage full while staging | yes | yes | **To do** | I15, after staging lands (the staging branch tests its own route; the harness adds "no duplicates, no loss" across Staging). |
| Keeper cases: a staged file missing, changed or evicted before *Import keepers*; Photos denied during it | n/a | n/a | **To do** | I15, after I12. |

Acceptance criteria:

- **Every case above runs in one suite on Linux and in CI**, and asserts the five points. The suite is the evidence for exit criterion 1.
- **A commit whose catalogue write is lost doesn't duplicate.** Two ways lose it: the app is killed between the save and the catalogue write, or the write fails after the save with every retry used (and the same two for a stage job: the file placed in Staging, the `markStaged` write lost). Before committing a unit the engine writes a pending-commit marker; if the marker can't be written, the unit isn't committed and the job ends `.catalogueUnavailable` as today. A marker left behind is resolved before any diff at the next launch, and again whenever the catalogue becomes available after a `.catalogueUnavailable` end: for a Photos commit the engine looks for the asset by the original filename and capture date (`PHAssetResource.originalFilename`) and writes `.imported` if found, else clears the marker; for a stage commit it looks for the file in its Staging day folder, under its name or a numbered one, with its size, and writes the staged fact if found. Section 3.1 (I20's design) settles where the marker lives (`PendingCommitFile`, a model of its own in V4), how the lookup works with Limited Access and with the album setting on and off, and the API: I7 adds the store calls, I9 writes and clears the marker, and I15 implements the resolution. The Linux tests use the fake library and `FailingCatalogue`; the Photos lookup is CI only. If no lookup proves reliable, the fallback is to leave the file `.new` and accept one possible duplicate, said in the outcome line, for Shamil to accept.
- **Engine bugs the harness finds are fixed in the engine, not worked around in the tests.** The harness (I22) records a failing case with `withKnownIssue` and a note, so its pull request stays a test change; I15 fixes them.
- **Bench:** a cable pull and a Wi-Fi drop at three points in a real file, and a camera powered off mid-import (I5).

Could change with: D1 (what exit 2 times); the staging branch's fallback for a Photos denial; D11 (same-name cameras sharing a folder).

### 3.1 Pending commits (I20's design)

Written on 11 Nov from `main` at f7a4f9e (`ImportEngine+File.swift`'s `commit` and `commitAndRecord`, `PhotosLibraryDestination`, `SystemPhotoLibrary`) and the staging branch's first commit (37b4f87: `StagingFolderDestination`, `FolderPlacer`, Catalogue V3's `markStaged`). Nothing here is built; I7, I9 and I15 build it, and the bench proves the Photos side. It is written to D1–D14's recommendations; the end of this section says where another answer changes it.

**The gap it closes.** `commitAndRecord` calls the destination (`used.commit(unit)`), then upserts the `.imported` row with up to `catalogueWriteAttempts` (2) tries and no backoff. Between the two the file is in Photos (or placed in Staging) and the catalogue doesn't know. Two things lose the row: iOS ends the app (or it crashes) after the save, and the write fails every try (the job then ends `.catalogueUnavailable` with `rowWritten: false`). Either way the next diff reads the file as new and the next import saves it again. The commit itself runs in an unstructured task, so cancelling or stopping the job doesn't cause the gap; only a kill or a failing store does. A Photos change interrupted by the app's death may still be completed by the system's photo library service (`unverified` either way), so the design assumes the asset may or may not exist.

**Which way to be wrong.** A lookup that answers "found" for a file that isn't there marks it imported (or staged) and it is never offered again: a loss. One that answers "not found" for a file that is there gives a second copy: a duplicate. The exit forbids both, but a loss can't be undone by the person and a duplicate can, so every doubtful answer below is "not found", and the resolution never writes to Photos or to Staging, only to the catalogue.

**Where the marker lives: a model of its own (recommended).** The three options I20's entry names:

| Option | For | Against |
| --- | --- | --- |
| A list on the V4 job record | No new model. | Written per unit, so a read-modify-write of an encoded list on the job record with two commits in flight; ties commit safety to History's fields, which D6 can still change or push to V5. |
| A field on the unit's `CameraObject` rows | The clearing write is the row write itself. | A pair's marker is split over two rows and needs a unit id to regroup; the destination's details (Staging root and day folder, the date the asset was given) widen `CameraObject` for a few seconds' use; if the catalogue syncs after 1.0, a device-local fact would ride on a synced row. |
| **`PendingCommitFile`, a model of its own** | One row per file, grouped by commit, so a pair is one commit with two rows (as `CullMark` writes both halves together); independent of D6 and of `CameraObject`'s meaning; can be kept out of any synced configuration later (it names this iPhone's Photos library and Staging root); "every unresolved commit" is one fetch of a table that is empty almost always. | A second write per unit. Clearing it in the same store save as the row (below) makes that write as safe as a row field. |

`PendingCommitFile` (V4, I7): `commitID: UUID?`, `jobID: UUID?`, `writtenAt: Date?`, `destination: String` (`"photos"` or `"staging"`, default `"photos"`), `stagingRoot: String?` (V3's `StagingRoot` raw value), `stagingFolder: String?` (the day folder relative to the root, `Staging/<camera>/<YYYY-MM-DD>`), the file's identity as `CameraObject` keeps it (`cameraKey`, `identityKey`, `folder`, `filename`, `captureDate`, `size: Int64`), `format: String`, `role: String` (`"single"`, `"raw"` or `"processed"`) and `assetDate: Date?` (the exact `Date` the asset or the placed file was given: `StagedFile.captureDate`). Every attribute optional or defaulted, no unique attribute, no relationship (forgetting a camera removes its markers by `cameraKey`, explicitly), pinned names.

**Written and cleared.** All of it in `commitAndRecord`, which already runs whether or not the job is current:

1. **Before the destination is called**, the engine writes the unit's marker (`beginCommit`), with the same number of tries as the row. The marker's id is the commit's existing token (`commitsInFlight`'s key), so the engine can tell its own live commits from leftovers. If the marker can't be written, nothing is sent to the destination: the downloaded copy is deleted (a resumable partial too, since no checkpoint could be recorded either), the file goes back to the queue with no retry counted and not failed, and the job ends `.catalogueUnavailable`, as a failed row write ends it today.
2. **A Photos refusal that switches the job to Staging** (3311, the staging branch's fallback) rewrites the marker under the same id with the staging destination before the staging commit; if that write fails, step 1's ending applies (Photos refused, so nothing was saved and the downloaded file is still there to delete).
3. **A commit that fails** (no space, rejected, staged file missing) removes the marker (`abandonCommit`, one try; a leftover is harmless, below).
4. **A commit that succeeds** writes its rows and removes the marker **in one store save** (`finishCommit`): `.imported` upserts for a Photos asset, `markStaged` for a staged copy, then the marker rows deleted, then one `save()`, rolled back as a whole if it fails (`SwiftDataCatalogue` already rolls back a failed save). A row written with its marker left behind, or a marker cleared with no row, can't happen. Same number of tries as today's upsert. If every try fails, the result is `rowWritten: false` as today, and the engine also keeps the writes it couldn't make in memory (`unrecordedCommits[id]`), so a resolution later in the same launch writes exactly them with no lookup.

Writing the asset's identifier into the marker as soon as `save` returns, before the row, was considered and dropped: it is a catalogue write that can fail the same way, and the window it would cover (between `save` returning and `finishCommit`) is far shorter than the save itself, which is where a kill lands. Nor can the marker be written from inside the change block, where the placeholder's identifier is first known: the block is synchronous and runs on Photos' own queue, so the catalogue's actor can't be awaited from it.

**A Photos commit is resolved by a lookup in the library** (I15, in `PhotosBridge`, behind `#if canImport(Photos)`):

- **Only with read access.** `PHPhotoLibrary.authorizationStatus(for: .readWrite)` is read, never requested (no prompt at launch). `.authorized` and `.limited` look; `.notDetermined`, `.denied` and `.restricted` answer *can't look* and the marker waits (below).
- **By the date the asset was given, then by original file names.** `PHAsset.fetchAssets(with: .image, options:)` with a predicate on `creationDate` from `assetDate` − 1 s to `assetDate` + 1 s (the asset's date is the camera's whole second, set as `PHAssetCreationRequest.creationDate`; that Photos keeps it as set and to the second is `unverified`, hence the window) and `includeHiddenAssets = true` (a hidden photo is still imported). For each candidate, `PHAssetResource.assetResources(for:)`: a match is an asset whose original resources (types `.photo` and `.alternatePhoto`) are exactly the unit's, role for role, by `originalFilename` with ASCII case folded (D13). A single ARW doesn't match a pair's asset, nor the other way round. Size can't be compared (no public size on `PHAssetResource`), so the match is the 8 Nov rule's name and second, with the role standing in for size; two cameras' files with one name and second already count as one (the accepted risk).
- **One match or more:** found; the first match's `localIdentifier` becomes the rows' location (several matches mean the photo is in Photos already, more than once, and nothing here makes that worse). **None:** not found. Assets in Recently Deleted aren't fetched, so a photo deleted since reads as not found and may be imported again, which is what the person would expect.
- **The album, on or off, resolves the same way.** The lookup is library-wide and never consults the album: the photo may be outside the album because the album refused content (`AlbumIssue.doesNotAcceptPhotos`), the person removed it or deleted the album, or the setting changed since. A found asset that is not in the album isn't added to it: the resolution doesn't write to Photos.
- **Under Limited Access** a fetch returns the person's selection; assets the app created are added to it (Apple's WWDC 2020 session on the limited library), which is `unverified` on iOS 27, as is whether the person can take them out of the selection afterwards. If they aren't visible, the lookup answers not found and the photo is saved again. Until the bench confirms visibility, a not-found under `.limited` is counted apart and worded as a possible duplicate (below), never silent.
- Also `unverified`: that `originalFilename` reads back as `PHAssetResourceCreationOptions.originalFilename` set it for the α7C II's ARW and JPG, and that assets saved into an iCloud Shared Library are returned by the default fetch.

**A stage commit is resolved by looking in its day folder** (I15, `PhotosBridge`'s `StagedCopyFinder`, pure Foundation, Linux-tested over temporary folders). The final name isn't known when the marker is written: `FolderPlacer` gives a clashing file "NAME (2).EXT" and a pair one shared number. So the marker holds the folder, and the finder lists it:

- The root from the `StagingLocator` now (the iCloud container's Documents folder, or the app's own); a marker for iCloud Drive while iCloud Drive isn't available answers *can't look*.
- For each file of the unit, a candidate is a regular file named as `FilesFolderNaming.fileName(forCameraFile:)` makes it, or its `numbered(_:_:)` form, with ASCII case folded, whose size equals the identity's. A pair matches only with both files under the same number. Where several numbers match, the highest wins (the newest placement); an older copy with the same name and size is the same file's bytes, so picking it marks the file staged correctly and leaves only a spare copy, never a loss.
- The modification date (`FolderPlacer` sets it to the capture date before the move) breaks ties when it is readable, but is not required: whether it survives an iCloud upload and eviction is `unverified`.
- An evicted file shows as an iCloud placeholder; whether its size can be read without downloading it (the URL's resource values) is `unverified`, and one whose size can't be read is not a match. A freshly placed file is unlikely to be evicted before the next launch.
- Found: `markStaged` with the found path and `stagedAt` from the marker's `writtenAt`. Not found: the marker is removed and the file stays new; if it was in fact placed under a name the finder didn't recognise, Staging holds a copy no row points to (the bench check below shows whether it happens; reconciling staged files deleted or added in Files is the staging branch's PR 7).

**When resolution runs.** `resolvePendingCommits()` runs in the engine, one pass at a time (a caller arriving during a pass awaits it), and skips any marker whose id is a commit still in flight in this process.

- **At launch**, called by `AppModel` once the catalogue is open and the engine made (after the engine's work-folder prune), before anything else asks the engine for a diff. Browse may read its badges meanwhile; when the pass reports a change, Browse reloads them.
- **Before every engine diff**: the listing in `runJob` and `append` call it right after the existing `settleCommits(ofJobsOtherThan:)`. With no markers it is one empty fetch. This is what covers "when the catalogue becomes available after a `.catalogueUnavailable` end": nothing uses the catalogue again until the next job, reconnect or append, and that diff resolves first, writing the in-memory `unrecordedCommits` for this launch's own commits and looking up the rest.
- **Order with I13**: work-folder prune, then pending commits, then I13's reset of `.partial` rows whose file is missing, then the diff. A Photos commit found writes `.imported`, which already clears a `.partial` row's offset and file; a stage commit found goes through `markStaged`, which turns a `.partial` row back to new and clears them. Not found touches only the marker, and I13's reset deals with a partial file the commit consumed.
- **Outcomes per marker:** *found* (rows written, marker removed in one save, `finishCommit`); *not found* (marker removed, `abandonCommit`; the file reads new); *can't look* (marker kept; the file reads as its rows say, new or partial, so nothing is held back and nothing is lost; the next pass tries again). A marker kept because Photos access is denied is harmless: no Photos save can happen until access returns, and the first diff after it returns resolves the marker first. A marker left by a failed `abandonCommit` resolves as not found, or as found if a later retry of the same file saved it, which is also right. No age limit is needed.
- `pendingCommits()` failing (the store still unavailable) ends the pass with nothing done; the diff that follows fails as today and the job ends `.catalogueUnavailable`.

**The fallback**, if the bench shows a lookup isn't reliable (say, app-created assets invisible under Limited Access): the marker is still written and resolved, but in the failing case the lookup answers not found without looking (counted in `possibleDuplicates`), the marker is removed, the file is left new, and the possible duplicate is said, in the log and in the next Import outcome ("1 photo from an interrupted import may now be in Photos twice"), for Shamil to accept as section 3 says. The marker is still worth writing in that case: without it the app couldn't even say so.

**The API.** Catalogue (I7, in `CatalogueStore`, both stores, in the shared contract tests):

```swift
public struct PendingCommit: Sendable, Hashable, Codable {
    public enum Destination: Sendable, Hashable, Codable {
        case photos
        case staging(root: StagingRoot, folder: String)   // folder: "Staging/<camera>/<YYYY-MM-DD>"
    }
    public enum Role: String, Sendable, Hashable, Codable { case single, raw, processed }
    public struct File: Sendable, Hashable, Codable {
        public var identity: ObjectIdentity
        public var format: PTPMediaKind
        public var role: Role
        public var assetDate: Date?
    }
    public var id: UUID             // the commit's token
    public var jobID: UUID?
    public var destination: Destination
    public var files: [File]        // a pair: the RAW first, as CommitUnit.files
    public var writtenAt: Date
}

public enum CommitWrite: Sendable, Hashable {
    case imported(CatalogueRecord)
    case staged(ObjectIdentity, format: PTPMediaKind, at: StagedLocation)
}

// CatalogueStore gains:
func beginCommit(_ pending: PendingCommit) throws        // inserts, or replaces the commit with the same id
func finishCommit(_ id: UUID, writing writes: [CommitWrite]) throws   // the writes and the marker's removal, one save;
                                                                     // the writes alone when no marker has that id
func abandonCommit(_ id: UUID) throws                    // removes it; nothing happens when there is none
func pendingCommits() throws -> [PendingCommit]          // every unresolved commit, oldest first
```

`forgetImports(camera:)` also removes that camera key's markers, so a later pass can't mark forgotten files imported again. Contract tests: begin then finish leaves the rows and no marker; begin then abandon leaves neither; a replace keeps one commit; `finishCommit` on a store whose save fails leaves the marker and no row (`InMemoryCatalogue` applies all or nothing within one actor call; SwiftData's half in CI); a pair's two files round-trip as one commit.

PhotosBridge (I9 adds `commitTarget`; I15 the lookups):

```swift
public enum CommitTarget: Sendable, Hashable {
    case photosLibrary
    case stagingFolder(place: StagingPlace, folderPath: String)
}
// ImportDestination gains (nonisolated, synchronous):
func commitTarget(for unit: CommitUnit) -> CommitTarget
// StagingFolderDestination computes folderPath with the same function its commit uses, so the two can't drift.

public struct AssetQuery: Sendable, Hashable {
    public var creationDate: Date
    public var resources: [AssetCreation.Resource]   // roles and original file names only; fileURL unused
    public init(_ asset: AssetCreation)              // built from AssetCreation(unit:options:), so roles match the save
}
public enum AssetSearch: Sendable, Hashable {
    case found(localIdentifier: String)
    case notFound(underLimitedAccess: Bool)
    case cannotSearch
}
// PhotoLibraryClient gains:
func findAsset(_ query: AssetQuery) async -> AssetSearch

public struct StagedCopyFinder: Sendable {
    public struct Wanted: Sendable, Hashable {
        public var filename: String          // the camera's name, as the marker keeps it
        public var size: UInt64
        public var modificationDate: Date?   // the marker's assetDate; a tie-breaker only
    }
    public init()
    // Each file's path relative to `root`, in the unit's order; nil unless every file is found (a pair under one number).
    public func find(_ wanted: [Wanted], in folder: String, under root: URL) -> [FileLocation]?
}
```

Engine (I9 writes and clears; I15 resolves):

```swift
// ImportEngine's init gains:
commitLookup: any CommitLookup = NoCommitLookup()   // NoCommitLookup answers .cannotLook: markers wait, nothing guessed

public protocol CommitLookup: Sendable {
    func look(for pending: PendingCommit) async -> CommitLookupAnswer
}
public enum CommitLookupAnswer: Sendable, Hashable {
    case found([CommitWrite])
    case notFound(underLimitedAccess: Bool)
    case cannotLook
}

extension ImportEngine {
    public func resolvePendingCommits() async -> PendingCommitReport
}
public struct PendingCommitReport: Sendable, Hashable {
    public var foundInPhotos: Int
    public var foundInStaging: Int
    public var notFound: Int
    public var possibleDuplicates: Int    // not found under Limited Access, or by the fallback
    public var waiting: Int               // can't look yet
}
```

`CommitLookup` and its answer are declared in `ImportEngine`, which already sees both `Catalogue` and `PhotosBridge`; the engine maps a `CommitTarget` to a `PendingCommit.Destination` (`StagingPlace` to V3's `StagingRoot`) when it writes the marker. `CommitResult` gains `.markerNotWritten` for step 1. The production `CommitLookup` (AppUI wiring, I15) composes `SystemPhotoLibrary.findAsset` with a `StagedCopyFinder` over the app's `StagingLocator`; Linux tests use a fake that answers from what a recording destination committed. `EngineTrace` gains one case per marker resolved (camera file name and outcome only), worded by I8's `EngineTraceWording`; `possibleDuplicates` reaches the next Import outcome's wording.

**Tests that prove it** (I15 unless named). Linux: a kill between the save and the row, simulated by an engine whose destination commits and whose `finishCommit` never lands, then a second engine over the same `InMemoryCatalogue` and a lookup that answers found: one `.imported` row with the asset's identifier, no marker, and the next job doesn't commit the file again; the same with not found (the file reads new and is imported once); a write that fails every try then a job later in the same launch (replayed from memory, no lookup asked); a marker that can't be written (nothing committed, the job ends `.catalogueUnavailable`, the file queued again next time; I9); the 3311 switch rewriting the marker (I9); a pair resolved as one commit; a marker of a commit still in flight not touched by a pass run from `append`; each of these for a stage commit too, with `StagedCopyFinder` over a temporary folder that holds "DSC00001 (2).ARW". CI only: `SystemPhotoLibrary.findAsset` against an asset the test saves, with and without an album. **Bench** (I15 adds the check to [iteration-2-bench.md](iteration-2-bench.md)): a Debug-only launch argument that ends the app right after a destination returns and before `finishCommit`; relaunch and import again, with full access, with Limited Access and nothing selected, with the album setting on and off, and once staging to iCloud Drive; each time the photo is in Photos or Staging once and Browse reads it imported or staged.

**Where another answer changes this.** D13 (b): names compare byte for byte in the Photos match and the finder. D10 (b) or (c): undated files get the modification date as `assetDate`, and the lookup works unchanged because the marker keeps the exact `Date` given. D11 (a): Staging folders named by display name change the stored `stagingFolder`, not the resolution; the Photos lookup ignores albums either way. D6: none, because the marker isn't on the job record. D2, D3: none; a file whose stage commit is unresolved has no staged row, so the cull screen doesn't list it and removal can't reach it. The staging branch: if its engine route ends up recording staged copies as `.imported` rows with a `.file` location (its interim form) rather than `markStaged`, `CommitWrite.staged` becomes an `.imported` write and the finder's result its location. iCloud sync of the catalogue (after 1.0): `PendingCommitFile` stays in a local-only configuration.

## 4. History screen and the tab bar

| Requirement | Status | Note |
| --- | --- | --- |
| `ImportJob` model | **Built**, unused | V1 and V2: camera, jobID, startedAt, finishedAt, selection, bytesTotal, bytesDone, outcome, cascade from `Camera.jobs`. "Nothing writes these yet." |
| Fields History needs: files imported / skipped / failed, purpose (import, stage, keepers), destination, carrier, album identifier, the selection's parameters (date-range bounds; the content keys of picked and of failed files) | **To do** | I7 (schema V4). The pending-commit marker isn't a job-record field: it is a model of its own (section 3.1). V1's `selection` is only the string "all-new", "range" or "picked", which leaves nothing to re-queue a range or picked job from. |
| A store API for jobs (record, update, list per camera and overall) | **To do** | I7, in both stores. |
| The engine writes a job record at start, at each pause and at the end | **To do** | I9. |
| History screen: past jobs with counts, bytes, duration and outcome; tap opens the album in Photos | **To do** | I10. |
| *Resumable* row for a job that stopped early; tap reopens Import with the remaining files queued | **To do** | I10 (needs the camera connected; otherwise the row says to connect it). |
| Re-run a failed job | **To do** | I10, from the failed files' content keys I7 keeps. |
| *Forget imports* per camera | **To do** | Store call I7, UI I10. |
| Stage jobs and keepers jobs in History | **Open** | Shamil (D6). |
| Tab bar, the running import as its bottom accessory | **To do** | I10. `LiveRoot.swift` says it "waits for Iteration 2"; `RootView` is a navigation stack today. |
| History numbers match the Import screen (files done and total, bytes, ETA) | **To do** | I9 records from the same `ImportProgress` the Import screen shows. |

Acceptance criteria:

- **Every job leaves one record, whatever ends it.** Completed, cancelled, stopped (with its kind), catalogue unavailable, or the app killed (a record with no end time reads as *Stopped early* at the next launch). Test (Linux, I9): each `JobOutcome` and a kill mid-job, against `InMemoryCatalogue`.
- **The record's counts equal the job's last `ImportProgress`.** Test (Linux): a job with imported, skipped and failed files, compared field by field.
- **History lists jobs newest first, grouped by day, with the camera's name, never its key or serial**, the counts ("48 imported, 2 skipped"), bytes in decimal MB or GB, the duration, and the outcome worded as the Import screen words it. VoiceOver reads one line per job. Model tested on Linux; the screen CI only (I10).
- **Tapping a job shows where its files went** (D6). No public API opens the Photos app, one album, or a folder in the Files app; the URL schemes that do are undocumented and risk App Review, so both are `unverified` and not relied on. With public API only: a Photos job's row names its album (the stored album identifier is kept for when iOS offers more), and a stage job's tap opens a document picker (`UIDocumentPickerViewController` with its `directoryURL` set) on that job's Staging folder.
- **A *Resumable* row** appears for a job that stopped early with files left, and only while those files are still not imported; tapping it with the camera connected opens Import with them queued, rebuilt from the job's stored selection (*all new* again, the stored date range, or the stored picked content keys matched against the listing), and the engine's diff decides, so nothing already imported is queued.
- **Re-run a failed job** queues exactly the job's failed files that are still not imported (or, for a stage job, not staged), matched by content key against the current listing, and nothing else; a failed file no longer on the card is listed as missing. Test (Linux): a job with imported, skipped and failed files, one failed file imported since by another job; the re-run queues only the rest (I10, over I7's records).
- ***Forget imports* for a camera** forgets that camera key's `.imported` and `.skipped` rows after a confirmation that says the photos stay in Photos and could be imported again: a row without a staged location is deleted; a row with one (V3 keeps the staged fact on the `CameraObject` row) goes back to `.new` and keeps its staged location, so a file still in Staging stays on the cull screen and can still be removed from Staging. Because "already imported" ignores the camera key, a file also imported under another key stays imported (stated in the confirmation's footer). It never touches Photos, Staging, marks or the card. Contract tests in both stores (I7), including: forget a camera with one imported-and-staged file, and `stagedRecords` still lists it.
- **The tab bar** has Cameras (with Browse pushed), Staging (D5) and History, Settings staying where it is; the running import is the tab bar's bottom accessory, and tapping it opens the Import screen. Focus returns where it was after the Import sheet closes (as built in the HIG pass). CI only.
- UI test path "Browse → select → import → history" (proposal, "Testing strategy"): it needs a camera, and a simulator-backed app would make the test-only `PTPSimulator` a dependency of shipping code, so it waits on D14; with D14's recommendation I18 tests the screens that need no camera and the full path moves to Iteration 5's review-build simulator mode.

Could change with: D6; whether the tab bar's bottom accessory API behaves under iOS 27 as on iOS 26 (CI and bench).

## 5. App Intents

| Requirement | Status | Note |
| --- | --- | --- |
| "Import new photos from <camera>" | **To do** | I16. Nothing exists (no `AppIntents` import anywhere). |
| "How many new photos are on the camera?" | **To do** | I16. |
| A camera `AppEntity` (the camera's name; keyed by the camera key; never the serial) and an `AppShortcutsProvider` | **To do** | I16. |
| What runs in the background, which destination, live or last-known count | **Open** | Shamil (D7). |

Constraints that shape it: a USB import needs the app in front (decision 1); a Wi-Fi join needs the app in front (`applicationIsNotInForeground`; the W14 hold); an MTP listing takes 65–123 s; a proximity wake shows a reminder and never starts an import (Iteration 4); auto-import on connect is Iteration 4's.

Acceptance criteria (with D7's recommended answers):

- **"Import new photos from <camera>" opens the app** (`supportedModes` foreground, or `openAppWhenRun` where the SDK still uses it) and starts the same import Browse's *Import* starts for *Select all new*, with the remembered Import-button choice (Photos or Stage), and says so in its result ("Importing 48 new photos to Photos"). With the camera not connected it opens the camera's Browse with its last-known card and says the camera isn't connected. With Photos access never asked, it asks in the app as *Import* does. It never joins Wi-Fi from the background.
- **"How many new photos are on the camera?" answers from the last-known listing**, with its age ("12 new photos when the card was last read, today at 14:05"), counting what *Select all new* would pick (not imported, not staged, stills with a date); while a USB camera is connected and listed it answers from the live listing. It runs without opening the app.
- **The camera entity shows the camera's name only.** Two cameras with one name are told apart by "last connected" in the picker.
- **Code lives in `AppUI` behind `#if canImport(AppIntents)`**, with the count's logic a pure function tested on Linux (listing + states + staged states → count), and the intents CI only. Whether App Intents declared in a package need an `AppIntentsPackage` conformance listed from the app target is `unverified`; if the app target needs a file, it is one small file in the synchronised folder, which keeps the target a shim.
- **Bench:** each intent from Shortcuts and Siri, with the camera on USB, on Wi-Fi and absent (I5).

Could change with: D7; App Store review of an intent that opens the app (none expected).

## 6. Diagnostics export

| Requirement | Status | Note |
| --- | --- | --- |
| Product logging to the unified log, names, sizes and times only | **Built** | #85 onwards: `BenchLog` and `OSLogBenchLog` (subsystem the bundle ID, about 90 call sites); W20 #112: `TransportTrace` and `TransportTraceWording`; `IPLinkDiagnostics` logged at close. |
| Private data never logged (serial, camera name, Wi-Fi name and password, hardware ID, PTP/IP GUID) | **Built** | Keys hashed per launch; `JoinFailure` carries no text; `TransportTraceWordingTests` feeds a fake name, password, GUID and serial through a whole connection and checks no line holds them. |
| The engine's own decisions in the log (skips, failures, checkpoints, retries, reconnects) | **Built** (wiring CI only) | I8: `EngineTrace` is public, with `EngineTraceSink` (`.none` default) taken by `ImportEngine.init`; AppUI's `EngineTraceWording` words each event as one `engine:` line (exact wording, level and privacy tested on Linux); `LiveRoot` passes `.bench(log)`. `BenchLog` is level-aware (`note(_:level:)`, notice by default) and `OSLogBenchLog` maps it, so a file that failed, a job the engine stopped, the catalogue being unavailable (in a job or at launch), a destination error, a job the engine refused to start and a Wi-Fi recovery giving up are error-level and nothing else is. New lines: the job resumed after a reconnect and the first byte after it (D1's timings). |
| Camera DeviceInfo and firmware version logged | **Partial** | Wi-Fi built in I4 (from `IPLink`'s DeviceInfo, through PTPKit's parser). USB MTP moves to I8 or later: `USBLink` reads no DeviceInfo today and no `ImageCaptureCore` API for the version is confirmed, so it waits for a GetDeviceInfo over the PTP pass-through or what the bench shows (`unverified`). MSC has none. The proposal's firmware risk row wants it. I8 adds none of that: the export's header carries the Wi-Fi firmware read this launch, only when exactly one camera is known (the read carries no camera key). |
| Settings › *Export Diagnostics…*: an opt-in archive the person shares themselves | **Built** (row CI only) | Core I4; I8: `DiagnosticsExporter` (header, rolling file for earlier launches and the unified log for this one, redacted with the catalogue's private values, one file in a folder of its own under Caches), `SettingsModel`'s export flow, the row in `SettingsScreen`, the share sheet through `SharePresenter`; the folder is removed when the sheet closes, when Settings closes and at launch. `RollingLogFile` is the second log destination (`AppLogging` in `LiveRoot`). |
| What the archive holds, how far back, MetricKit | **Open** | Shamil (D8). |
| A redaction test over the export | **To do** | I4. |

Acceptance criteria:

- **Nothing leaves the phone unless the person shares it.** The proposal's Settings row says the export "writes an `OSLog` archive"; an app on iOS can't produce a `.logarchive` (`unverified` for iOS 27: `OSLogStore` reads entries but has no API to write an archive), so a plain-text file replaces it, a departure for Shamil to carry into the proposal. The export writes one plain-text file to a temporary folder and hands it to the share sheet (`SharePresenter`, already used for *Share as JPEG*); the folder is emptied afterwards, as `JPEGScratch` does. No network call.
- **The archive** holds a header (app version and build, iOS version, iPhone model class, each camera's model and firmware version, the link it last used, the export time) and the app's own log entries from `OSLogStore(scope: .currentProcessIdentifier)`, filtered to the app's subsystem, oldest first. How far back depends on D8 (the current process only gives this launch's entries).
- **Redaction by construction and by test.** A pure redactor (Linux) runs over every line before it is written: anything shaped like a MAC or hardware ID, a 12-hex-digit UDN tail, a UUID, an IPv4 address outside the camera's fixed gateway, or a value the app knows is private (the stored network name, camera serials, the PTP/IP GUID) is replaced. Test (Linux): a stream with a fake serial, network name, password, GUID, hardware ID and a home-style address in every field yields an archive containing none of them; and the existing `TransportTraceWordingTests` stay green.
- **The engine's trace reaches the log** as one worded line per event (`EngineTraceWording`, tested on Linux for exact wording and for no private data), wired in `LiveRoot` like `TransportTrace.bench(wifiLog)`.
- **The Settings row** says what is in the file and that nothing is sent anywhere until they share it. VoiceOver label and hint. CI only.
- The privacy manifest stays as it is unless the export reads file timestamps or disk space beyond what is declared (`FileTimestamp` is declared).

Could change with: D8; Apple's `OSLogStore` scopes on iOS 27 (`unverified`: whether entries from earlier launches can be read by the app itself).

# Part 2: culling over staged files (decision-pack 3.21 B, as the 11 Nov decisions change it)

## 7. Culling

### 7.1 Prerequisites

| Requirement | Status | Note |
| --- | --- | --- |
| Staging: the destination, `FolderPlacer`, V3's *staged* fact, stage jobs, the Import menu, badges and Settings | **Built** | The staging PR (11 Nov): PhotosBridge staging and `FolderPlacer`, Catalogue V3's *staged* fact, stage jobs in the engine, and the Import menu, *Staged* badge and Settings' staging section in AppUI. Staging writes to On My iPhone until the iCloud entitlement follow-up lands. |
| iCloud container and App ID capability (Phase 0 of the staging plan) | **Open** | Shamil, before any build signs with the iCloud keys. |
| RAW+JPEG pairing in the engine | **To do** | I6. `RawPairingRule` (same folder, same stem, within 1 s; no pair without a date) is built and tested (#80); the engine's `commitUnit(for:)` returns `.single`. |
| `stagedRecords(camera:)` (and across cameras), grouped by capture day | **To do** | I7. |

Acceptance criteria for pairing (I6):

- **A RAW and its JPG become one Photos asset** (JPG or HEIF as the photo, ARW as the alternate, the original choice as set), through the engine, for both links and for stage jobs' folder placement (both files of a pair land in the same Staging day folder under one stem, which the staging branch's layout already gives).
- **Both files are downloaded before the unit is committed**; with 2 in flight the pair's files may download together, and nothing else of that pair is committed early.
- **Partial pairs**: if one half is skipped (missing after a replug, no date) the other is committed alone and the outcome says so; if one half fails for a real error after its retries, the other half waits until the job ends and is then committed alone, with the failure listed; a pause keeps a downloaded half on disk until the job continues.
- **Resume and diff are pair-aware**: a pair with one half imported and one not imports the missing half as a single file into the same album (Photos can't add a resource to an existing asset); a pair already imported isn't queued; a partial half resumes as any partial does.
- Tests (Linux): pairs, partial pairs, pauses mid-pair, a stall on one half, 1 and 2 in flight, against the fake library and `SimulatedCameraLink`; the real Photos save of a pair stays CI only (built, `PhotosLibraryDestinationTests`).

### 7.2 StagingFolderLink: Staging as a camera

| Requirement | Status | Note |
| --- | --- | --- |
| A `CameraLink` over staged files | **To do** | I2. |

Acceptance criteria:

- **`StagingFolderLink: CameraLink`** in `CameraTransport` (pure Foundation, Linux-tested) is made from a list of staged entries (original folder, name, capture date, size, format, and the staged file's URL) handed in by the caller from `stagedRecords`, so `CameraTransport` doesn't depend on `Catalogue`.
- **`list()` returns those files as `CameraItem`s with their original identity**, so the engine's diff, rows and Browse's badges treat a keeper exactly as the card's file (the card's *Imported* badge follows after *Import keepers*).
- **`bytes(of:into:)` copies, never moves**, the staged file into the engine's work folder, checks the size against the entry, and answers `itemNotFound` if the file is gone or its size changed. On iOS the read is coordinated (`NSFileCoordinator`), and an evicted iCloud file is downloaded first (`startDownloadingUbiquitousItem(at:)`, then waiting for its status), with progress; both behind `#if os(iOS)`, with a plain reader on Linux.
- **Capabilities:** no resume, 2 downloads in flight (a local copy), no thumbnails from the link (the cull screen reads its own), no events; `close()` releases nothing on the card.
- **Its descriptor gets a carrier of its own.** `CameraLink` needs a `descriptor` whose `CameraMode` is today `.usb` or `.wifi`, and the carrier decides *did suspend* pausing, the continued task and the wording. Recommended: a new `CameraCarrier.staging` with `CameraMode.staging`, rather than reusing `.wifi`, whose wording and one-download rule don't fit. A keepers job reads local files, so it isn't paused on *did suspend* and continues in a continued task as a Wi-Fi job does (`unverified` that iOS keeps a local copy and Photos save running in one), with its own wording ("Importing keepers from Staging"). The new case reaches every exhaustive switch: `CameraTransport`'s `CameraDescriptor.swift` and `CameraLinkCapabilities.swift` (`defaults(for:)`), and in `AppUI` `Wording.swift`, `CameraKeys.swift`, `CamerasScreen.swift` and `ImportModel.swift` (`pausesWhenTheAppLeaves`). Several of those files are the staging branch's, so I2 builds the link with a descriptor passed in by the caller (its tests use a stand-in) and I12 adds the case and its switch sites once staging has merged. The link's descriptor never makes a camera key: each keepers job is started with the staged files' own key (7.5).
- Tests (Linux): the listing's identities, copy-not-move, a missing file, a changed size, a slow reader with cancellation, and the engine importing from the link into the fake library with rows under the camera key the job is started with and the files' original identity. The coordinated and ubiquitous reader: CI compile; eviction on the bench (I5).

### 7.3 The cull screen and the loupe

| Requirement | Status | Note |
| --- | --- | --- |
| Cull session model: units by capture day, pairs as one unit, marks, navigation, undo | **To do** | I3 (pure), wired in I11. |
| Preview source: a pair's JPG, else the ARW's embedded preview, else a `CIRAWFilter` render | **To do** | I3. `CoreImageJPEGMaker` already renders an ARW with `CIRAWFilter` and falls back to the largest embedded preview. |
| Fetch ahead while the person looks | **To do** | I3. |
| Full-screen loupe: swipe, zoom, Keep / Reject, stars, EXIF line | **To do** | I11. |
| Where culling lives and whether it also works from the card | **Open** | Shamil (D5). |
| Measure the next-preview time on the real files | **Bench** | I5. Nothing measured: the only card-side preview read was a 320×214 embedded JPEG at about 0.43 s over USB MTP; a staged file read locally is expected to be fast but is unmeasured, and so is downloading an evicted one. |

Acceptance criteria:

- **The cull screen lists staged files by camera and capture day**, newest day first, with counts ("Today: 120 staged, 34 kept, 60 rejected"), from the catalogue, with no camera connected.
- **A RAW+JPEG pair is one unit** with one mark and one rating (D4), shown by its JPG.
- **The loupe** shows one unit full screen; swipe left and right moves between units; a pinch zooms to 100 %; *Keep* and *Reject* are buttons and swipe-up / swipe-down gestures with VoiceOver actions; stars 0–5 are optional; marks save at once (the catalogue, I7), and an undo reverts the last mark. A small EXIF line (capture time, shutter, aperture, ISO, focal length) reads from the file with ImageIO if D5 says the loupe is also Browse's full-screen preview.
- **Previews are fetched ahead**: the next 3 and the previous 1 units are decoded at screen size while the person looks, and evicted iCloud files ahead are downloaded further ahead (10 units), with a progress ring on a unit still downloading. Memory stays under the 150 MB budget with at most 5 decoded screen-size images held. The fetch-ahead window and the eviction policy are pure logic, tested on Linux with a fake loader and a manual clock.
- **Rendering:** a pair's JPG is shown as it is; a lone ARW shows its embedded preview at once and a `CIRAWFilter` render replaces it when ready (if iOS decodes the α7C II ARW at all: Iteration 1's week-1 bench check, unrecorded; if not, the embedded preview stays and the loupe says so, as *Copy as JPEG* does).
- **Bench:** time from swipe to a sharp preview for local and evicted files, and memory over a 360-file cull (I5). Decision-pack 3.21 leaves a numeric target to Shamil once measured.

### 7.4 Marks in the catalogue

| Requirement | Status | Note |
| --- | --- | --- |
| Keep / Reject and an optional 0–5 rating per unit, kept by a planned migration | **To do** | I7 (schema V4). |
| Keyed by content key so a mark follows the file between the card and Staging | **To do** | I7. |
| Whether a Reject outlives its staged copy | **Open** | Shamil (D3). |

Acceptance criteria:

- **A separate `CullMark` model keyed by content key** (name with ASCII case folded, capture second, size; one row per file, both halves of a pair written together), not fields on `CameraObject`, so a mark exists for a file with no `CameraObject` row under that camera and survives *Forget imports*. Optional attributes, no unique attribute (CloudKit-compatible), pinned names. `CatalogueStore` gains `setMark(_:rating:for:)`, `marks(of:)` and `clearMarks(of:)`, in the shared contract tests for both stores.
- **Marks never touch the card or the staged file** (no XMP in Iteration 2).
- **A reject outlives its copy** if D3 says so: the engine's *all new* diff, Browse's *Select all new*, the intent's count and a re-queued *Resumable* job skip rejected content keys, and Browse shows a *Rejected* badge that a tap can lift (I21). Without it, `clearStaged` makes a removed reject new again, and the next *Select all new* imports it.

### 7.5 *Import keepers*

| Requirement | Status | Note |
| --- | --- | --- |
| Keepers go to Photos through the engine with the normal Photos route | **To do** | I12, with I2 and I6. |

Acceptance criteria:

- ***Import keepers*** on a day, a camera or all of Staging runs one engine job per staged camera key, in sequence: the engine runs a job for exactly one `CameraKey` and writes every row under it, and the per-camera album is keyed by it (`AlbumPlan`, `camera:<key>`), so staged files from two cameras, or from one camera's MSC and MTP keys, can't share a job. Each job runs over a `StagingFolderLink` listing only that key's kept units, to Photos with that key's album (or the album D11 settles), with the original choice, pairing, retry and continued-task rules unchanged, and progress on the Import screen as any job; the Import screen says which of the jobs is running ("Keepers, 2 of 3 cameras") and the outcome adds them up. Each job leaves its own History record. Rows are written under that key and the files' original identity, so the card shows them as imported.
- **Already-imported keepers** (imported separately before) aren't saved again; the engine's diff skips them and the outcome says so.
- **Photos access denied or restricted during *Import keepers*:** the files are already in Staging, so the job stops with "Photos access needed" (and the Settings link when denied), and nothing is removed from Staging. It doesn't stage them again: every Photos `ImportRoute` carries a fallback destination, and on a 3311 the engine switches the rest of the job to it (`ImportEngine+File.swift`), which on the staging branch is the staging destination; a keepers job uses a Photos route with no fallback, and the engine ends such a job with a Photos-access stop (I12). Test (Linux): a 3311 during a keepers job writes nothing to Staging, and the later keepers' jobs don't start.
- **A keeper missing or changed in Staging** is skipped with its reason; it isn't removed from the catalogue's marks.
- **No camera needed.** The job runs with the card absent.

### 7.6 Removing the staged copies afterwards

| Requirement | Status | Note |
| --- | --- | --- |
| After the keepers are in Photos, the staged copies of keepers and rejects are removed from Staging | **To do** | I12. |
| Whether removal asks first, and what happens to unmarked files and to keepers that failed | **Open** | Shamil (D2). |
| Nothing is ever deleted from the camera | **Built** by construction | The `CameraLink` contract has no delete call and 1.0 never deletes (`CameraLinkCapabilities.deletes` only records whether the camera could); the app stays read-only on the card. A test asserts no delete reaches a camera link in any culling flow (I12). |

Acceptance criteria (with D2's recommended answer):

- **At the end of *Import keepers*, one confirmation** lists what will be removed ("Remove 120 staged files? 34 keepers are in Photos; 86 rejects will be deleted from Staging. Unmarked files stay."); its default action removes them. Files are removed under file coordination (iCloud) or plainly (On My iPhone), then `clearStaged` is called for each. A day folder left empty is removed.
- **Only what is safe is removed:** a keeper is removed only if its save succeeded (both halves of a pair); a keeper that failed stays with its mark; unmarked files stay; rejects are removed only when every keeper of the same day has been imported or given up, so a failure doesn't cost the person the rejects they might revisit. A keeper is given up when the person changes its mark to Reject or clears it.
- **A removal that fails** (file busy, iCloud error) leaves the row staged and says so; the next cull screen offers it again.
- **Only recorded paths are removed.** The remover acts on each file's recorded staged copy (`stagedRelativePath`), resolved with `StagedLocation.fileURL(in:)`, and on nothing else: never on everything under Documents/Staging, and never on a row whose path is empty (unknown) or outside `Staging/`, which the resolver refuses. Builds before 11 Nov imported to Files in a folder per camera directly under Documents, with no rule against the name, so a camera named "Staging" left imported originals in Documents/Staging, where staging on this iPhone now nests its camera folders; those originals have no staged row and are never removed. Removing an emptied day folder removes only a day folder a removed path named, and only when it is empty.
- Tests (Linux): the removal rules over a temporary folder with the plain remover, including a failed keeper, a pair half failing, a failed keeper then given up, and unmarked files; files under Documents/Staging with no staged row (an older Files import in a "Staging" camera folder) and a row with an empty path are left alone; the coordinated remover CI compile, bench on iCloud.

### 7.7 Schema and catalogue order

See section 8: V3 is staging's; cull marks and job records go in V4.

### 7.8 Culling with on-device models (spike, outside the exit)

| Requirement | Status | Note |
| --- | --- | --- |
| A short spike on Shamil's own photos: Vision aesthetics scores, closed eyes and blur, near-duplicate groups from feature prints; what it gets right and the time per frame | **Open** | Shamil runs it during Iterations 2–3; outside both exits; built for 1.1. Apple frameworks only; suggestions only, the person confirms. With staging, the input is the staged files, not card previews. No work item: it doesn't ship in Iteration 2. |

## 8. Catalogue schema versions, in one planned order

| Version | What | Status | Who |
| --- | --- | --- | --- |
| V1 (1.0.0) | Camera, CameraObject, ImportJob | **Built**, frozen | #83; builds 17.1 and 18.1. `theShippedSchemaIsUnchanged` pins it. |
| V2 (2.0.0) | V1 + `Camera.bluetoothPeripheralID` | **Built** | W4 #92; lightweight V1 → V2. |
| V3 | The *staged* fact (`StagedLocation`: relative path, root, staged-at) on `CameraObject` | **Staging** | The staging branch; lightweight V2 → V3, pinned names. |
| V4 | `CullMark` (content key, mark, rating, marked-at); `ImportJob` gains files imported / skipped / failed, purpose, destination, carrier, album identifier, the selection's parameters (date-range bounds; the content keys of picked and of failed files, as a related model or an encoded list, I7's choice within the CloudKit rules); `PendingCommitFile`, the pending-commit marker (section 3.1) | **To do** | I7, after V3 is on `main`; I20 chose the marker's model (section 3.1), so it doesn't need a stage of its own. |
| V5 (reserved) | An indexed content-key column filled in the stage's `didMigrate` | **Later** | Only if a slow diff is measured. |

Why one V4 for marks and job records: both are Iteration 2's, both are additive, and every stage is compiled and tested only by CI's SwiftData run; one stage instead of two halves the migrations shipped between the staging build and the internal TestFlight. If the job-record fields aren't settled when the marks are ready (D6), the marks ship as V4 and the job records become V5, and the order stays V3 → V4 → V5. The pending-commit marker was designed first (I20, wave 1) for the same reason: it is a model of its own (`PendingCommitFile`, section 3.1) and goes into the same V4 rather than a stage of its own. If the job records move to V5 (D6), the marker stays in V4 with the marks.

Acceptance criteria (each stage):

- A versioned schema with a stage in `CatalogueMigrationPlan`, lightweight, no unique attribute, every attribute optional or defaulted, every relationship optional with an inverse; names pinned by a test like `theShippedSchemaIsUnchanged`.
- **Migration tests open stores written by earlier builds:** a populated V1 store (as 17.1 and 18.1 wrote it), a V2 store (as 19.1 wrote it) and a V3 store (as the first staging build will), each opened as V4 with every value carried. CI only; the PR says so.
- `CatalogueStore`'s new calls are in the shared contract tests and pass against `InMemoryCatalogue` on Linux and `SwiftDataCatalogue` in CI.
- No catalogue write on the main actor (built rule).

# Part 3: the internal TestFlight on 15 Jan 2027

## 9. Internal TestFlight readiness

| Requirement | Status | Note |
| --- | --- | --- |
| TestFlight upload of the production app | **Built** | #78 onwards: `testflight.yml` (run by hand, approved each time); builds 17.1 to 19.1 shipped to the bench iPhone. It checks the icon and the signed entitlements. |
| PR checks: the app for Simulator and device, every package's tests in the Simulator, `swift test` on Linux | **Built** | `app.yml`, `packages-linux.yml`. |
| Hotspot Configuration on the App ID | **Built** in effect, confirm it | Builds after W12 (#102), 19.1 among them, passed `testflight.yml`'s signed-entitlement check, which refuses an archive without it. ci.md already has the step that ticks it on the production App ID; Shamil to confirm it was ticked and date it in ci.md. |
| Multicast Networking entitlement | **Open** (Apple) | Requested on 8 Nov; the proposal's internal TestFlight milestone has it "ideally granted". Nothing in Iteration 2 waits on it (decision-pack 3.11); ci.md has the step to tick it on the App ID when granted, before any build signs with it. |
| iCloud container and capability (staging Phase 0) | **Open** | Shamil, before the first build that signs with iCloud. |
| A wider internal group than the bench iPhone | **Open** | Shamil (D12): who, and which build. |
| The hardware plan on the bench iPhone for the definition of done | **Open** | Shamil (D12). Recommended: the Iteration 2 bench sheet (I5) run on the 15 Jan build, with the open Iteration 1 checks. |
| Xcode Cloud | **Later** | ci.md keeps it "later"; `testflight.yml` serves the 15 Jan build. |
| String Catalog with plural variants ("1 file", "3 files") | **To do** | I17. No `.xcstrings` exists. |
| VoiceOver and Dynamic Type checked on the bench iPhone | **Bench** | Built in the HIG passes (#88, #94); unchecked on the device. I5. |
| Card free space on the Cameras screen (MTP only, after the catalogue) | **Partial** | The wording exists (`CamerasWording.deviceStatus(carrier:batteryPercent:freeBytes:)`) and `CamerasModel.deviceStatusLines` takes the value, but no caller passes one. I17 adds the USB-side read (`GetStorageInfo` through `USBLink`'s pass-through; it gave free space on 1 Nov) and supplies it. An Iteration 1 leftover. |
| UI tests: "Browse → select → import → history" against a simulator-backed build | **Open** | Shamil (D14): a simulator-backed app would link the test-only `PTPSimulator` into shipping code. With the recommendation, I18 tests the screens that need no camera, and the full path is Iteration 5's (review-build simulator mode). |
| Performance metrics (`XCTClockMetric`, `XCTMemoryMetric`) on the integration suite | **Later** | Not in Iteration 2's builds; the budget clause of the definition of done is checked on the bench (I5). |
| Which budget rows the definition of done checks | **Partial**, then **Open** | Checked on the bench (I5): the memory high-water mark (≤ 150 MB), wired throughput on the USB 2 bench iPhone (≥ 30 MB/s, ARW; decision-pack 3.3 records JPG in MTP below it) and Wi-Fi throughput on the camera's network (≥ 8 MB/s). Open for Shamil: "camera visible after connect" and "first screen of thumbnails", whose 1.0 targets decision-pack 3.3 leaves to Shamil; USB 3 throughput isn't measurable on the bench; Energy was dropped (7 Nov). |
| Privacy manifest | **Built**, review | W19 #111: tracking off, no collected data, `UserDefaults` and `FileTimestamp`. I17 reviews it against the export, the intents and staging (a disk-space reason only if the staging branch adds the free-space check). |
| Layered app icon | **Open** | Shamil, in Icon Composer. |
| "What to Test" notes for testers | **To do** | I17. |
| Onboarding pack for the second engineer (18 Jan) | **To do** | I19: proposal, spike findings, Iterations 3–4 backlog, this backlog, the codebase. |
| Carried from Iteration 1, for Shamil | **Open** | Whether a *Copy as JPEG* fetch waits behind an import or is refused; the RAW + HIF partner; chunked 0x9211 or GetObject for new Wi-Fi files (iteration-1-backlog.md section 6, iteration-3-4-backlog.md section 3). Not repeated in the decisions below. |

Acceptance criteria:

- **The 15 Jan build** passes every PR check, uploads through `testflight.yml`, signs with exactly the entitlements `app.yml` and `testflight.yml` expect (Hotspot Configuration, and iCloud if staging's Phase 0 is done), and reaches the internal group D12 names.
- **Every new screen** (History, the cull screen and loupe, the Staging tab, the diagnostics row) has VoiceOver labels, Dynamic Type up to the largest accessibility size, and strings in the String Catalog with plural variants, in British English.
- **The definition of done** is met as D12 settles it: all PR suites green; the bench sheet's checks green on the camera's current firmware; no new error-level `OSLog` entries in a 200-file import (I8 makes real failures log at error level, so the check can fail; I5's 200-file import counts them, and the diagnostics export is how the log is read); the budget rows listed above met on the bench, with the rest as Shamil settles them.

# Decisions for Shamil

**Decided (Shamil, 11 Nov): every recommendation below.** Shamil chose D2 (one confirmation), D3 (remember rejects) and D5 (staged files only, in their own Staging tab) individually, and accepted the recommendation for D1, D4 and D6–D14 as written. The table keeps the options for the record; the *Recommendation* column is now the decision.

| # | Question | Options | Recommendation |
| --- | --- | --- | --- |
| D1 | Iteration 2's second exit criterion ("re-plugging after a pull resumes within 2 s"), which can't be met over USB. | (a) Decision-pack 3.6's wording for USB only. (b) 3.6's wording for USB, plus a Wi-Fi target: after a drop the file resumes from its checkpoint within 5 s of the session reopening (measured reopens 2.5 s and 2.9 s, one run each). (c) Keep "2 s" and time it from the card being listed again. | (b). It states what USB can do and gives Wi-Fi a measurable target with headroom. |
| D2 | After *Import keepers*, removing the staged copies: ask first? What about unmarked files and keepers that failed? | (a) Remove automatically once every keeper is in Photos. (b) One confirmation at the end of *Import keepers*, default Remove; failed keepers and unmarked files stay; rejects of a day go only when its keepers are all in. (c) Keep everything until the person clears Staging. | (b). It does what the 11 Nov decision says, with one tap of safety, and never deletes a file whose keeper failed. |
| D3 | Does a Reject outlive its staged copy? Once removed, `clearStaged` makes the file "new" again, so *Select all new* would offer it at the next import. | (a) Keep the Reject mark; *Select all new* skips rejected files; Browse shows a *Rejected* badge a tap can lift. (b) Forget rejects once their copies are removed. | (a). Otherwise every reject comes back at the next import. |
| D4 | Marks: per file or per RAW+JPEG pair, where they are kept, and sidecars. | (a) One mark and rating per pair, stored per file in a separate `CullMark` model keyed by content key, catalogue only. (b) Per file. (c) (a) plus XMP sidecars in Staging so other apps see ratings. | (a) in Iteration 2; sidecars later if asked. |
| D5 | Where culling lives, whether it also works from the card, and whether the loupe is Browse's "full-screen preview with EXIF". | (a) Staged files only, from a Staging tab beside Cameras and History; the loupe shows a small EXIF line; no card loupe in Iteration 2. (b) Also from the card in Browse (the 8 Nov plan; card previews are 320×214, about 0.43 s each in MTP). (c) Staged only, entered from each camera's Browse. | (a). Culling needs no camera once staged, so it can't live only under a connected camera, and card previews are too small for a full-screen loupe. |
| D6 | History and staging: which jobs appear, what tapping does, what *Forget imports* clears, and what *Resumable* re-queues. | (a) All jobs (Import, Stage, Keepers) with their purpose; a Photos job's row names its album and a stage job's tap opens a document picker on its Staging folder (public API only, section 4); *Forget imports* deletes imported and skipped rows that have no staged location and returns those that have one to new with the staged fact kept, never touching marks; *Resumable* re-queues with the original purpose. (b) Import and Keepers jobs only. | (a). |
| D7 | App Intents: background or app, destination, live or last-known count, any third intent. | (a) "Import new photos" opens the app and uses the remembered Import-button choice; "How many new" answers from the last-known card with its age, live only when a USB camera is connected and listed; no third intent. (b) "Import new photos" always to Photos. (c) Add "Stage new photos". | (a). Both transports need the app in front, and the remembered choice is what the person last did. |
| D8 | Diagnostics export: what it holds, how far back, MetricKit. | (a) This launch's own log entries (`OSLogStore`, current process) plus a header with versions and camera firmware, redacted; MetricKit later. (b) Also keep a rolling file of the app's own lines (last 3 launches, at most 5 MB, in Caches) so a problem before a relaunch can be exported. (c) (a) plus opt-in MetricKit crash and hang payloads in the export. | (b). Bench problems often show after a relaunch, and the file stays on the phone until shared. MetricKit with Iteration 5's crash-free target; TestFlight already sends crashes for testers. (b) writes a file the proposal's Local files section doesn't allow for ("Nothing else is written to disk"), so choosing it means an exception carried into the proposal, as the plain-text export itself does (section 6). |
| D9 | MTP `PersistentUniqueObjectIdentifier` as an identity (about 385 ms per object, 152 s for 391 files). | (a) Drop it: the 8 Nov rule needs no handle identity. (b) Read it for new objects only. | (a). |
| D10 | Files without a capture date. | (a) Keep skipping them, and say how many in the Import outcome. (b) Import them with the file's modification date. (c) Show them for an explicit pick only. | (a). DCF stills carry a date; a date-less file has no identity to stop it being imported twice. |
| D11 | One camera in MSC and MTP gets two keys; two bodies can share a name. One album and Staging folder per body, per key, or per name? | (a) Name albums and Staging folders by the camera's display name, so MSC and MTP share them, and continue a paused job across modes by content; two bodies with one name share them (the 8 Nov accepted risk). (b) Keep one per key as today. | (a). |
| D12 | Internal TestFlight: who, and what the hardware plan means for the definition of done. | (a) Named testers in the team's internal group from the 15 Jan build; the hardware plan is the Iteration 2 bench sheet run on that build. (b) The bench iPhone only until Iteration 3. | (a), with the names for Shamil to add. |
| D13 | Folding ASCII case in file names when matching "already imported" (an implementation choice, decision-pack 3.22). | (a) Confirm: DSC00001.ARW and dsc00001.arw are one file. (b) Byte-for-byte names. | (a). DCF names are upper-case ASCII; the camera can't write both. |
| D14 | UI tests and a simulator-backed build. The proposal's "Browse → select → import → history" UI test needs a camera; composing the app over `SimulatedCameraLink` would make `PTPSimulator`, which AGENTS.md keeps a test-only dependency on `PTPKit` alone, a dependency of the shipping `AppUI` target. | (a) Move the full path to Iteration 5's review-build simulator mode (proposal, Iteration 5). (b) A separate Debug-only app target or scheme that links `PTPSimulator`; AGENTS.md must allow it first. (c) In Iteration 2, UI tests only of screens that need no camera (History, Settings, the cull screen) over an `InMemoryCatalogue` seeded by a Debug launch argument, with no `PTPSimulator` in any shipping target; the full path as in (a). | (c). It tests Iteration 2's new screens now without changing the layering rule, and the camera path waits for the build the proposal already plans. |

# Work plan

Items are numbered I1 to I22, so they don't clash with the wireless plan's W-numbers; I20 to I22 were added after review and are numbered last so the earlier references stay valid. **Parallel with staging** means the item touches none of PhotosBridge's destination files, Catalogue's schema or store, ImportEngine's route, commit or diff, AppUI's Browse, Import or Settings models and screens (or `Wording.swift` and `LiveRoot.swift`, which the branch also edits), or `PTPSimulator`'s integration tests (the branch edits `EngineAgainstSimulatorTests.swift`, and anything driving the engine there uses the APIs it replaces: `FilesFolderDestination` is deleted, `DestinationKind.filesFolder` becomes staging, `ImportResult.files` changes and `ImportRoute.photos(...)` gains a staging place), so it can run while `staging-destination` is open. Models and efforts follow the table in `CLAUDE.md` (at most *high*); code that only CI can compile is never given a cheaper model. Every item runs `make test` before it commits, says in its PR what was compiled and run where, and records its status in this backlog.

| Wave | Items | Starts when |
| --- | --- | --- |
| 1 | I1, I2, I3, I4, I5, I20 | Now, beside the staging branch. |
| 2 | I6, I7, I8, I22 | The staging branch (V3, stage jobs, the Import menu) is merged; I7 also needs I20. |
| 3 | I9, I11, I13 | Their wave 2 dependencies are merged. I9 and I13 both touch `ImportEngine.swift` and `ImportEngine+File.swift`: merge one, rebase the other. |
| 4 | I10, I12, I14, I21 | Their wave 3 dependencies are merged. I12 and I14 both touch `ImportModel.swift` and the Import screen's wording, I12 and I21 both touch ImportEngine, and I14 and I21 both touch `Wording.swift`: merge one, rebase the others. |
| 5 | I15, I16, I18 | Their wave 4 dependencies are merged. |
| 6 | I17, I19 | Before the 15 Jan build. |

### Wave 1 (parallel with staging)

**I1. Fault hooks in the simulators.** *Goal:* the simulator behaviours section 3's cases need and don't have yet, tested at link level, so the harness (I22) only composes them. *Packages and files:* `PTPSimulator`: `Sources/SimulatedLink/SimulatedCameraLink.swift` (throughput per tick, power-off with no return, reconnect at another location, a late loss from the old session for I13), `Sources/SimulatedLink/InMemoryByteChannel.swift` (throttling), `Sources/PTPSimulator/PTPIPResponderCore.swift` and `PTPIPSimulatorServer.swift` (restart at another port or address, throttling), and tests in `Tests/SimulatedLinkTests/` and `Tests/PTPSimulatorTests/`. No engine, destination or integration test: nothing the staging branch replaces. *Depends on:* nothing. *Parallel with staging:* yes (the branch edits only `Tests/IntegrationTests/EngineAgainstSimulatorTests.swift` in this package, which I1 leaves alone). *Model:* sonnet, high. *Tests:* Linux: each hook at link level (bytes per tick on the manual clock, a power-off that never returns, a reconnect through the location provider to the new address, a stale loss after `loseSessionAndReopen()`), with the existing simulator suites green.

**I2. `StagingFolderLink`.** *Goal:* Staging readable as a camera, so *Import keepers* reuses the engine (section 7.2). *Packages and files:* `CameraTransport`: `Sources/CameraTransport/Staging/StagingFolderLink.swift`, `StagedFileReader.swift` (plain reader; coordinated and ubiquitous reader behind `#if os(iOS)`), tests. The link takes its descriptor from the caller; the `CameraCarrier.staging` / `CameraMode.staging` case section 7.2 recommends touches `CameraDescriptor.swift`, `CameraLinkCapabilities.swift` and AppUI's `Wording.swift`, `CameraKeys.swift`, `CamerasScreen.swift` and `ImportModel.swift`, which the staging branch edits, so I12 adds it. *Depends on:* nothing (it takes plain entries; the catalogue adapter comes in I12). *Parallel with staging:* yes. *Model:* sonnet, high. *Tests:* Linux: identities, copy-not-move, missing and changed files, cancellation, the engine importing from it into a fake library; CI compiles the iOS reader.

**I3. Cull session core and preview pipeline.** *Goal:* the pure logic of culling, ready for the screen (section 7.3). *Packages and files:* `AppUI`: `Sources/AppUI/Culling/CullUnit.swift` (units by day, pairs through `RawPairingRule`), `CullSession.swift` (navigation, marks through a `CullMarkWriting` protocol, undo, keepers), `PreviewSource.swift` (pair JPG, embedded preview, render; reusing `CoreImageJPEGMaker`), `PreviewPrefetcher.swift` (window, eviction, download-ahead), `EXIFSummary.swift`. *Depends on:* nothing (written to D4 and D5's recommendations). *Parallel with staging:* yes (new files; reads PhotosBridge's `Pairing.swift` only). *Model:* sonnet, high. *Tests:* Linux: grouping, pair as one unit, marks and undo, the fetch-ahead window with a fake loader and manual clock, the memory cap; the ImageIO and Core Image parts CI only.

**I4. Diagnostics core and firmware logging.** *Goal:* the export's archive and redaction, and the camera firmware in the log (section 6). *Packages and files:* `AppUI`: `Sources/AppUI/Diagnostics/DiagnosticsRedactor.swift`, `DiagnosticsArchive.swift`, `LogStoreReader.swift` (behind `#if canImport(OSLog)`), and the rolling file if D8 chooses (b); `CameraTransport`: `Diagnostics/TransportTrace.swift` (a DeviceInfo event), `IP/IPLink.swift` (emits it), and `AppUI` `Wireless/TransportTraceWording.swift` (its line). The firmware version comes from PTPKit's existing parser (`PTPFirmwareVersion`, `DeviceInfo.firmwareVersion`), not a new one. *Depends on:* D8 (written to its recommendation). *Parallel with staging:* yes. *Model:* sonnet, high. *Tests:* Linux: the redactor over a stream holding every kind of private value, the archive's header and order, the new trace line's wording and its privacy; the log-store reader CI only.

**I5. Iteration 2 bench sheet.** *Goal:* one sheet for what only the camera and the iPhone can prove, so Shamil can run the checks while code is built. *Files:* `docs/iteration-2-bench.md` (new). Contents: Iteration 1's open checks (first file after *Continue* compared byte for byte, *did suspend* without a continued task, screen on, a 100-file import in MSC and MTP with its memory peak, the RAW decode check); a 200-file import with its count of error-level log entries (the definition of done), its memory peak and its throughput (the budget rows section 9 lists); MSC and MTP capture second and size for three files; cable pulls at three points; Wi-Fi drops at three points; camera powered off mid-import; replug-to-resume times for D1; the loupe's preview times, local and evicted; staged-file eviction and removal on iCloud; each intent; the export's contents; VoiceOver and Dynamic Type on the new screens. Each check names the log line that records it, and lists lines that don't exist yet for I8. *Depends on:* nothing. *Parallel with staging:* yes. *Model:* sonnet, medium. *Tests:* none (a document).

**I20. Pending-commit design.** *Goal:* settle, before I7 fixes V4, how a commit whose catalogue write is lost is found again (section 3). *Files:* a design section in this backlog (docs only). It picks where the marker lives (the V4 job record, a field on the unit's rows, or a small model of its own) and when it is written and cleared; how a Photos lookup by original filename and capture date resolves it (`PHAssetResource.originalFilename` over assets fetched by creation date), with the album setting on and off and with Limited Access (`unverified` that assets the app saved stay fetchable under Limited Access); how a stage commit is resolved (the file at its Staging path, with its size); when resolution runs (at launch before any diff, and when the catalogue becomes available after a `.catalogueUnavailable` end); and the fallback if no lookup is reliable (leave the file new, say so in the outcome, for Shamil to accept). *Depends on:* nothing (reads `ImportEngine+File.swift` and the staging branch). *Parallel with staging:* yes (a document). *Model:* opus, high. *Tests:* none (a document); I7, I9 and I15 test what it settles. *Status:* written on 11 Nov as section 3.1, to D1–D14's recommendations, for Shamil's review: a `PendingCommitFile` model of its own in V4, written before the destination is called and cleared in the same store save as the rows; a library-wide Photos lookup by the asset's date and original file names (the album not consulted; created assets' visibility under Limited Access `unverified`); a stage commit found in its day folder by name, numbered name and size; resolution at launch and before every engine diff.

### Wave 2 (after staging merges)

**I6. RAW+JPEG pairs in the engine.** *Goal:* a pair is one Photos asset through the engine, for every link and job kind (section 7.1). *Packages and files:* `ImportEngine`: `ImportEngine+File.swift` (`commitUnit`), `ImportEngine+Driver.swift` (pair-aware ordering and holding a half), `ImportJob.swift`, `DownloadAttempt.swift`; reads `PhotosBridge`'s `Pairing.swift`; folder placement of pairs in Staging if the staging branch's placer needs it. *Depends on:* staging merged. *Parallel with staging:* no. *Model:* opus, high (commit and resume logic). *Tests:* Linux: pairs, partial pairs, a pause mid-pair, a stall on one half, 1 and 2 in flight, a half already imported, stage jobs keeping pairs together.

**I7. Catalogue V4: cull marks, job records, staged records and *Forget imports*.** *Goal:* the one planned schema stage after V3, and the store calls culling and History need (sections 4, 7.4, 8). *Packages and files:* `Catalogue`: `SwiftData/CatalogueSchemaV4.swift` (new), `CatalogueMigrationPlan`, `CatalogueStore.swift` (`setMark`, `marks(of:)`, `clearMarks`, `recordJob`, `updateJob`, `jobs(camera:)`, `stagedRecords(camera:)`, `forgetImports(camera:)`, and the pending-commit calls `beginCommit`, `finishCommit(_:writing:)`, `abandonCommit` and `pendingCommits()` as section 3.1 gives them), `InMemoryCatalogue.swift`, `CullMark.swift`, `JobRecord.swift`, `PendingCommit.swift` (`PendingCommit`, `CommitWrite`; the SwiftData model `PendingCommitFile`, one row per file, in `CatalogueSchemaV4.swift`) (with the selection's parameters: date-range bounds, picked and failed content keys); contract and migration tests. *Depends on:* staging merged (V3); I20; D3, D4, D6 (written to their recommendations). *Parallel with staging:* no. *Model:* opus, high (schema; the SwiftData side is verified only by CI). *Tests:* contract tests on Linux and in CI, including *Forget imports* on a camera with one imported-and-staged file (it stays in `stagedRecords`, back to new) and one imported file with no staged location (deleted), and a job record's selection parameters round-tripped; the pending-commit contract tests section 3.1 lists (begin then finish, begin then abandon, a replace, a failing save leaving the marker and no row, a pair as one commit, *Forget imports* removing the camera's markers); migration tests opening V1, V2 and V3 stores as V4 (CI only); pinned names.

**I8. Diagnostics wiring, the engine's trace in the log, and the export in Settings.** *Goal:* the export a person can use, and the engine's decisions in the log (section 6). *Packages and files:* `ImportEngine`: `EngineTrace.swift` (public sink with a `.none` default), `ImportEngine.swift` (init takes it); `AppUI`: `EngineTraceWording.swift` (new), `SettingsModel.swift`, `SettingsScreen.swift` (the row), `SharePresenter.swift`, `LiveRoot.swift` (wiring), `SystemServices.swift` (`OSLogBenchLog` maps a level to the logger's; today every line goes out at notice level, so the definition of done's "no new errors" can't fail) and `BenchLog` (a level-aware `note`, notice by default); the log lines I5 lists as missing (reconnect, resume, first byte after). Real failures go out at error level: a file failed after its retries, catalogue unavailable, a destination error, recovery giving up; pauses, stalls that recover and skips stay at notice. *Depends on:* I4, I5, staging merged. *Parallel with staging:* no. *Model:* sonnet, high. *Tests:* Linux: wording, privacy and level of every `EngineTrace` case (each failure case at error, the rest at notice), the settings model's export flow with a fake reader; the row CI only. Rebase on I6 if both touch `ImportEngine.swift`.

**I22. The fault-matrix harness.** *Goal:* exit criterion 1's evidence for every transport case in section 3, in one suite asserting no duplicates and no loss. *Packages and files:* `PTPSimulator`: `Tests/IntegrationTests/FaultMatrix*.swift` (new), over I1's hooks, the real engine, `InMemoryCatalogue` and a recording destination fake, written against the staging branch's merged APIs (`ImportRoute` with its staging place, the staging `DestinationKind`, the new `ImportResult`), so nothing is rewritten when staging lands. *Depends on:* I1, staging merged (its PhotosBridge and engine changes). *Parallel with staging:* no. *Model:* sonnet, high. *Tests:* every transport case × link × offset (10, 50, 99 %) × 1 and 2 in flight on USB, on Linux; failures in engine code recorded with `withKnownIssue` for I15.

*Built (11 Nov, on the staging branch):* `Tests/IntegrationTests/FaultMatrix{Support,CutTests,CaseTests,WireTests}.swift`, about 190 cases in 3 s on Linux: a recording destination (Photos and staging), the five points checked by one `MatrixBench.verify`, the engine on a manual clock, every wait bounded. Two engine bugs are recorded with `withKnownIssue` for I15 (the full-phone partial; the skipped Wi-Fi file's stray partial and row); each test says what to delete once the engine is fixed.

### Wave 3

**I9. Job records written by the engine, and the pending-commit marker.** *Goal:* every job leaves one record matching its last progress (section 4), and every commit is bracketed by a pending-commit marker (section 3.1). *Packages and files:* `ImportEngine`: `JobRecorder.swift` (new), `ImportEngine.swift` (start, pause, end, reconnect), and the pending-commit marker as section 3.1 designs it: `ImportEngine+File.swift`'s `commitAndRecord` writes it (`beginCommit`) before the destination is called, rewrites it on the 3311 switch to Staging, removes it on a failed commit, and replaces today's upsert loop with `finishCommit`, keeping unwritten writes in `unrecordedCommits`; `CommitResult.markerNotWritten`; `PhotosBridge`'s `CommitTarget` and `ImportDestination.commitTarget(for:)` (both destinations and the test fakes). *Depends on:* I6, I7. *Parallel with staging:* no. *Model:* opus, high (it now changes the commit boundary, which `CLAUDE.md` gives to opus). *Tests:* Linux: every outcome, a kill mid-job, counts equal to the last progress, a reconnect continuing one record; a marker written before every commit and gone after it (Photos and stage, single and pair), a marker that can't be written (nothing committed, the job ends `.catalogueUnavailable`, the file queued again), the 3311 switch rewriting it, a failed commit removing it, a `finishCommit` that fails every try leaving the marker and the writes in memory (`FailingCatalogue` gains switches for each call).

**I11. The cull screen and the loupe, wired.** *Goal:* culling a person can use, from a Staging tab (section 7.3). *Packages and files:* `AppUI`: `Culling/CullScreen.swift`, `LoupeView.swift`, `CullModel.swift` (new; the I3 session over `stagedRecords` and I7's marks), and a Staging screen opened from Cameras until I10's tab bar gives it a tab. *Depends on:* I3, I7, D2–D5. *Parallel with staging:* no. *Model:* opus, high (SwiftUI compiled only by CI). *Tests:* Linux: the model against `InMemoryCatalogue` and a fake preview loader; CI: the views, gestures' VoiceOver actions.

**I13. Partials in Caches, reconciliation, and session generations.** *Goal:* section 2's remaining items. *Packages and files:* `ImportEngine`: `ImportEngine.swift` (work-folder root, launch pass), `ImportEngine+File.swift`, `ImportPolicy.swift`; `Catalogue`: a call to reset a partial row's offset if the existing `markPartial` can't express it (in the store, so after staging); `AppUI` `LiveRoot.swift` (the Caches root). *Depends on:* I1 (the late-loss hook), I6 (engine files), staging merged. *Parallel with staging:* no. *Model:* opus, high (resume). *Tests:* Linux: a purged partial reset before the diff, pruning resetting rows, a late loss from a replaced session ignored, container-relative paths still resolving.

### Wave 4

**I10. History screen and the tab bar.** *Goal:* section 4's screen, *Resumable*, re-run, *Forget imports*, and the tab bar with the import as its accessory. *Packages and files:* `AppUI`: `History/HistoryModel.swift`, `HistoryScreen.swift` (new), `RootView.swift`, `LiveRoot.swift`, `ImportScreen.swift` (the accessory); the tab bar takes I11's Staging screen as its second tab. *Depends on:* I9, I11, D6. *Parallel with staging:* no. *Model:* opus, high (SwiftUI compiled only by CI). *Tests:* Linux: the model (grouping, wording, *Resumable* only while files are left and rebuilt from the stored selection, re-run queuing only the failed files still not imported, *Forget imports* confirmation text); CI: the screens, the stage job's document picker and VoiceOver labels.

**I12. *Import keepers* and removal from Staging.** *Goal:* keepers into Photos through the engine, then the staged copies removed as D2 settles (sections 7.2, 7.5, 7.6). *Packages and files:* `ImportEngine`: `ImportRoute.swift` (a Photos route with no fallback for keepers jobs), `ImportEngine+File.swift` (a 3311 on a route with no fallback ends the job with a Photos-access stop instead of switching destination); `CameraTransport`: `CameraDescriptor.swift` and `CameraLinkCapabilities.swift` (the `.staging` carrier and mode, section 7.2); `AppUI`: `Culling/KeepersImport.swift` (groups the kept units by staged camera key, builds one `StagingFolderLink` per key from `stagedRecords` and marks, and starts one job per key in sequence through `ImportModel`), `ImportModel.swift` (a keepers job and its sequence; `pausesWhenTheAppLeaves` for the new carrier), `Wording.swift`, `CameraKeys.swift` and `CamerasScreen.swift` (the new carrier's switch sites and wording), `Culling/StagingRemover.swift` (plain and coordinated); the confirmation in the cull screen. *Depends on:* I2, I6, I7, I11. *Parallel with staging:* no. *Model:* opus, high (deletion and identity). *Evicted keepers (from I2's review):* a staged file iOS has evicted after upload must download within the engine's 30 s stall limit, and `StagingFolderLink` reports progress only if `NSMetadataQuery` does (`unverified`, bench); so download evicted keepers ahead of the job, before it starts, and say so. *Tests:* Linux: a keepers job end to end against a temporary Staging folder and the fake library; staged files from two camera keys imported as two jobs, each key's rows and album its own; a 3311 mid-job writing nothing to Staging and starting no later job; the removal rules (failed keeper, pair half failing, unmarked files, rejects held back), and no delete ever sent to a camera link; the remover touching only paths recorded in `stagedRelativePath`, resolved with `StagedLocation.fileURL(in:)` (an empty or out-of-Staging path is skipped), so an older Files import in a camera folder named "Staging" (Documents/Staging, from builds before 11 Nov) is never removed (section 7.6); CI: the coordinated remover.

**I14. Capture zone and date-less files.** *Goal:* section 1's remaining identity items. *Packages and files:* `CameraTransport`: `CameraItem.swift`, the USB and IP listings; `ImportEngine`: `ItemIdentity.swift`; `AppUI`: the Import outcome's line for left-out files. *Depends on:* I6, D10. *Parallel with staging:* no. *Model:* opus, high (identity). *Tests:* Linux: a relisting 9 hours away matches; date-less files counted and worded; existing badge tests green.

**I21. Rejects stay rejected.** *Goal:* D3's recommendation: a reject whose staged copy was removed isn't offered again (section 7.4). *Packages and files:* `ImportEngine`: `ImportSelection.swift` and `ImportEngine+Driver.swift` (the *all new* diff, and a re-queued *Resumable* or re-run job, skip content keys with a Reject mark, read through I7's `marks(of:)`); `AppUI`: `BrowseModel.swift` (*Select all new* skips them; a *Rejected* badge; a tap that lifts it by clearing the mark), `BrowseScreen.swift` (the badge, its VoiceOver label and the lift action), `Wording.swift`. An explicit pick of a rejected file still imports it. The intent's count follows in I16. *Depends on:* I7, staging merged, D3. *Parallel with staging:* no. *Model:* opus, high (the badge and its action are compiled only by CI). *Tests:* Linux: *all new* and *Select all new* skip a rejected file whose staged copy was removed, a lifted reject is new again, an explicit pick imports it, a re-queued job skips it; CI: the badge.

### Wave 5

**I15. Fault matrix: engine fixes, destination, stage-job and keeper cases, and the commit boundary.** *Goal:* every row of section 3's table green, and exit criterion 1 met. *Packages and files:* `PTPSimulator` integration tests (the harness's new cases), `ImportEngine` (fixes for I1's known issues; `resolvePendingCommits()`, `CommitLookup`, `PendingCommitReport`, and the call before every diff), `PhotosBridge` (`PhotoLibraryClient.findAsset(_:)` with `AssetQuery` and `AssetSearch`, implemented in `SystemPhotoLibrary` behind `#if canImport(Photos)`; `StagedCopyFinder`, pure Foundation), `AppUI` (the production `CommitLookup`, the launch call in `AppModel`, Browse reloading its badges after a pass that changed something, and the possible-duplicate line in the Import outcome), `docs/iteration-2-bench.md` (the commit-boundary check). The resolution follows section 3.1: at launch, and before every engine diff, which covers the catalogue coming back after a `.catalogueUnavailable` end, for Photos and stage commits, with section 3.1's fallback if the bench shows a lookup unreliable. *Depends on:* I6, I9, I12, I13, I20, I22. *Parallel with staging:* no. *Model:* opus, high (debugging and commit logic). *Tests:* the whole matrix on Linux and in CI, including a kill between save and write and a catalogue write that fails after the save (`FailingCatalogue`), each for a Photos and a stage commit, and the rest of section 3.1's list; the Photos lookup CI only; the bench check with full and Limited Access, the album on and off, and staging to iCloud Drive. *Order with I13's reconciliation (found when wave 3 was integrated, 11 Nov):* a marker left from an earlier launch next to a partial row whose file is gone (the staging folder moved it, or Photos copied it and the engine discarded it, then the app was killed before `finishCommit`) today means a second copy and a marker that never goes away: `reconcilePartials()` resets the row to offset 0 and nothing reads `pendingCommits()` or `unrecordedCommits` yet. This isn't a regression (without the reset, the job's own partial check also copies from 0), but I15 must resolve leftover markers and `unrecordedCommits` before every job's diff, beside `settleCommits(ofJobsOtherThan:)` and `reconcilePartials()` in `ImportEngine+Driver.swift`, and write the resolution so it doesn't depend on the row still naming its partial file. Make the launch pass one call the engine owns (resolve, then reconcile), replacing `LiveRoot`'s bare `Task { await engine.reconcilePartials() }`, so the first job's pass waits for it instead of racing it. Test it with a stage job left partial, its file deleted, a marker written, and a new engine over the same catalogue: one staged copy and no marker left.

**I16. App Intents.** *Goal:* the two intents of section 5. *Packages and files:* `AppUI`: `Intents/CameraEntity.swift`, `ImportNewPhotosIntent.swift`, `NewPhotoCountIntent.swift`, `AppShortcuts.swift` (behind `#if canImport(AppIntents)`), `NewPhotoCount.swift` (pure), `AppModel.swift` (an entry point to start *Select all new*); at most one file in the app's synchronised folder if the package's intents need registering there. *Depends on:* I8 (the app's wiring settled), I10, I21 (the count skips rejected files), D7. *Parallel with staging:* no. *Model:* opus, high (compiled only by CI). *Tests:* Linux: the count over listings, imported, staged and rejected states, and its wording with the listing's age; CI: the intents build and their parameter summaries.

**I18. UI test target for the screens that need no camera.** Written to D14's recommendation (c); if Shamil chooses (b), AGENTS.md changes first and this item is replanned; with (a) alone it is dropped. *Goal:* UI tests of History, Settings and the cull screen; the proposal's "Browse → select → import → History" path moves to Iteration 5's review-build simulator mode. *Packages and files:* `App/ShutterBridge.xcodeproj/project.pbxproj` (a UI-test target, hand-edited with fresh 24-hex IDs), `App/ShutterBridgeUITests/` (new), a launch argument in `LiveRoot.swift` that, in Debug builds only, composes the app over an `InMemoryCatalogue` seeded with job records, staged records and marks (and, for the cull screen, a few generated images in a temporary Staging folder). No `PTPSimulator` in any shipping target. *Depends on:* I10, I11, D14. *Parallel with staging:* no. *Model:* opus, high (project file and UI tests compiled only by CI; the PR says so). *Tests:* the UI tests in CI's Simulator run.

### Wave 6

**I17. TestFlight readiness.** *Goal:* section 9's remaining items for the 15 Jan build. *Packages and files:* `AppUI`: a String Catalog (`Resources/Localizable.xcstrings`, British English, plural variants for counted words) and the strings moved to it; card free space on the Cameras screen (MTP, after the catalogue): `CameraTransport/USB/USBLink.swift` reads it (`GetStorageInfo` through the pass-through) and `CamerasModel` passes it to the existing wording; VoiceOver review of History, culling and the export; `App/ShutterBridge/PrivacyInfo.xcprivacy` review; "What to Test" notes. *Depends on:* I10, I11, I12, I16. *Parallel with staging:* no. *Model:* sonnet, high. *Tests:* Linux: wording tests updated to read the catalogue's keys; CI: the app builds with the catalogue, and the existing HIG tests stay green.

**I19. Iteration 2 close-out.** *Goal:* this backlog's statuses checked against the merged code, the bench sheet updated with what was run, and the onboarding pack for the second engineer (18 Jan). *Files:* `docs/iteration-2-backlog.md`, `docs/iteration-2-bench.md`, `README.md` (pointers). *Depends on:* all others. *Parallel with staging:* no. *Model:* sonnet, medium. *Tests:* none (documents).
