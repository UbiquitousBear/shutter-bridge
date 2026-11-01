# Iteration 1 backlog: wired import

> **Draft — finalise on day 10 from the findings.** Written from the proposal before the spike has measured anything. Each item names the spike findings that could change it. On 13 Nov 2026, edit or strike items to match [spike-findings.md](spike-findings.md), replace the proposal's targets with the measured numbers, and remove this note.

Iteration 1 is weeks 3–6 (16 Nov – 11 Dec 2026), Shamil alone. From [proposal.md](proposal.md), "Development iterations":

- **Builds:** `PTPKit` with unit tests and fixtures; `USBLink`; `ImportEngine` happy path; `Catalogue` schema; `PhotosBridge` with RAW+JPEG pairing; Cameras, Browse and Import screens; `PTPSimulator` v1 and CI on Xcode Cloud.
- **Exit criteria:** plug in, browse, select, import 100 files to Photos with correct dates and pairs; integration suite green on the simulator.

Not in Iteration 1 (proposal): identity and diff rules beyond the happy path, resume offsets and `.part` files, the fault matrix, History, App Intents and diagnostics export (Iteration 2); `IPLink`, SSDP, QR scan and the join flow (Iteration 3); the BLE proximity reminder, `BGContinuedProcessingTask`, Live Activity and auto-import (Iteration 4).

## 0. Production workspace

The Swift Package Manager workspace from the proposal's project layout, created only after the go/no-go.

Acceptance criteria:

- Packages `PTPKit`, `CameraTransport`, `ImportEngine`, `Catalogue`, `PhotosBridge`, `AppUI` and the test-only `PTPSimulator`, each building and testing alone.
- Dependencies follow `AppUI → ImportEngine → {Catalogue, PhotosBridge, CameraTransport} → PTPKit`, with `PTPSimulator` depending on `PTPKit` only.
- Swift 6 language mode with strict concurrency in every package; Apple frameworks only.
- `PTPKit` moves in unchanged from `Packages/PTPKit/`. Nothing from `Spike/` is carried in; the spike stays archived in `Spike/`.
- The workspace is committed (not generated), so Xcode Cloud needs no post-clone step.

Could change with: the go/no-go itself (whether `IPLink` stays a 1.0 package or waits for 1.1).

## 1. PTPKit

Done during the spike (`Packages/PTPKit/`, 57 tests passing with Swift 6.4 on Linux; the fixture tests skip until captures exist):

- PTP containers: encode and decode of command, data, response and event containers, sequences of containers, a transaction counter that wraps.
- Code tables: operations, responses, events, object formats, device properties, vendor extension, storage IDs, object handles. Sony vendor codes from libgphoto2 are marked unverified.
- Command builders: `GetDeviceInfo`, `OpenSession`, `CloseSession`, `GetStorageIDs`, `GetStorageInfo`, `GetNumObjects`, `GetObjectHandles`, `GetObjectInfo`, `GetObject`, `GetThumb`, `GetDevicePropValue`, `GetDevicePropDesc`, `GetPartialObject` and `GetPartialObject64`, Sony `SDIO_Connect` and `SDIO_GetExtDeviceInfo`.
- Datasets with decode, encode and public initialisers: `DeviceInfo`, `StorageInfo`, `ObjectInfo`; storage ID and object handle arrays; PTP date-time parsing; media kind from extension or format code; pair stem; object identity (camera serial, filename, capture date, size), with the true size passed in for objects of 4 GiB or more.
- `PTPPassThrough`: decodes `requestSendPTPCommand` replies in every layout Apple's documentation leaves open, and reports which one it saw.
- `PTPPartialRead`: chunk planning, 32- or 64-bit variant choice, the resume rule, 16 MiB checkpoints.
- PTP/IP framing, a stream decoder that never buffers a data phase, a transaction state machine, and responder-side encoders for tests and the simulator.
- Fixture tests for every captured `a7c2-<link>-<name>.bin`, and a garbage-input test across every decoder.

Remaining for Iteration 1:

- **Golden tests pass on the camera's bytes.** Acceptance: after `make fixtures`, every `a7c2-usb-*` fixture decodes and re-encodes to the same bytes; any failure is fixed in the codec, never in the fixture.
- **Unverified markings settled.** Acceptance: each code or layout a fixture proves loses its `unverified` note; each one it disproves is corrected, with a test.
- **Pass-through layout pinned.** Acceptance: `PTPPassThrough` has a test built from the layout day 4 observed; layouts that `ImageCaptureCore` never produced are either kept behind their tests or removed.
- **Round trip for every container type with randomised inputs** (the proposal's property tests). Acceptance: encode → decode is identity for seeded random containers and datasets.
- **Device property values,** only if the Cameras screen reads battery level over PTP. Acceptance: a decoder for the `GetDevicePropValue` reply of the properties the screen uses, tested against a captured reply.

Could change with: "Byte-range resume on USB" (if `GetPartialObject` does not pass through, `PTPPartialRead` serves Wi-Fi only); the pass-through layout and transaction renumbering ("ImageCaptureCore facts"); any fixture that disagrees with the spec.

Not in Iteration 1: an initiator-side cancel in `PTPIPTransaction` (the spike client drops the connection on any error mid-data-phase instead); a libFuzzer target (nightly, later); a parser for Sony's ExtDeviceInfo.

## 2. USBLink

The `CameraLink` implementation over `ImageCaptureCore`, in `CameraTransport`. Per the proposal, links are dumb pipes that answer list, info, thumb, bytes and events, and nothing else; each is an actor that owns its connection.

Acceptance criteria:

- **Discover:** an `ICDeviceBrowser` with the device mask the spike found to work surfaces each camera as a `CameraDescriptor` (name, serial, carrier). The serial comes from `GetDeviceInfo`, because `ICDevice.serialNumberString` is macOS-only.
- **Open:** opens the session, sends `GetDeviceInfo` and exposes the supported operations (`GetPartialObject`, Sony's vendor extension).
- **List and info:** returns object handles and `ObjectInfo` for every file on the card, newest first.
- **Thumb:** returns a thumbnail per object, by whichever route the spike measured as faster on USB.
- **Bytes:** writes an object, or a byte range of it, to a file URL without holding it in memory.
- **Events:** an `AsyncStream` of camera events (empty if the camera sends none over USB).
- **Errors:** every failure maps to one of the engine's four outcomes (retry now, retry on reconnect, skip this file, stop the job). A cable pull ends every pending call with "retry on reconnect"; nothing waits forever.
- **Numbers on the bench iPhone:** camera visible ≤ 2 s after connect, the 200-file card listed ≤ 2 s, and wired throughput at the figure the findings set (the proposal's target is ≥ 30 MB/s on the USB 2 iPhone, to be corrected on day 10).

Could change with: the USB mode and device mask that enumerate; whether `GetObjectHandles` passes through (if not, list from `ICCameraDevice.mediaFiles` and `ptpObjectHandle`); "Byte-range resume on USB" (if not, bytes come from `requestDownloadFile` per file); `usb.thumb.avg` against `GetThumb`; `usb.event.objectAdded`; the pass-through layout; `requestDownload`'s completion string; session survival on lock.

## 3. ImportEngine, happy path

The actor that runs discover, open, enumerate and diff, download and commit for one job.

Acceptance criteria:

- Imports a selection end to end through `USBLink` (or the simulator), into a temporary file per object, then `PhotosBridge`, then a catalogue row, then deletes the temporary file.
- Up to 2 downloads in flight on USB, with PTP commands serialised per link.
- Progress as an `AsyncStream<ImportProgress>` (files done and total, bytes, MB/s, ETA), published at most 4 times a second.
- A file that is already imported, by identity, is not queued again.
- Files added from Browse while a job runs are appended to it.

Could change with: `usb.download.throughput.parallel2` against `.serial` (if two in flight is no faster on USB, the limit becomes 1); "Byte-range resume on USB" (chunked `GetPartialObject` against `requestDownloadFile`); `usb.download.memory.peak` against the 150 MB budget.

## 4. Catalogue schema

The three SwiftData models from the proposal's data model, with writes through a `ModelActor`.

Acceptance criteria:

- `Camera` (`serial` unique, `model`, `friendlyName`, `lastSeen`, `preferredCarrier`, `autoImport`, `wifiSSID?`, `lastIP?`, `ptpipGUID`), `CameraObject` (`camera`, `filename`, `captureDate`, `size`, `format`, `state`, `resumeOffset`, `tempURL?`, `assetLocalID?`, `pairStem`) and `ImportJob` (`camera`, `startedAt`, `finishedAt?`, `selection`, `bytesTotal`, `bytesDone`, `outcome`).
- `(camera, filename, captureDate, size)` identifies a `CameraObject`; a second insert of the same identity updates the row instead of duplicating it. Unit tests cover it, including a filename reused after the camera's counter wraps.
- A versioned schema from the first release, so later migrations are planned rather than inferred.
- No catalogue write on the main actor.
- Open point: the proposal wants the schema CloudKit-compatible for a later opt-in, and SwiftData's CloudKit sync does not allow unique attributes. Decide whether uniqueness is enforced by the `ModelActor` instead of by the schema.

Could change with: whether ObjectInfo's capture date is present and stable, and whether DeviceInfo carries a serial (the identity depends on both); the mismatches the day-4 ObjectInfo step logs against `ICCameraFile`; how sizes of 4 GiB or more appear.

## 5. PhotosBridge with RAW+JPEG pairing

Acceptance criteria:

- Creates assets with `PHAssetCreationRequest` from file URLs, never from data in memory.
- An `.ARW` and a `.JPG` or `.HIF` with the same pair stem become one asset: the JPEG or HEIF as `.photo`, the ARW as `.alternatePhoto`. A lone ARW, JPEG or HEIF becomes its own asset.
- The camera's capture date (and GPS from EXIF, if present) is set on the asset.
- Asks for `.readWrite` access once, at the first import, and works with `.limited`. The prompt's text says that *Limit Access* with no photos selected is enough. The spike showed that add-only access can't create an album without bringing up the read/write prompt anyway (spike-findings.md, "Photos albums").
- Puts each import in an album: creates it the first time, stores its `localIdentifier`, finds it by that identifier (the title can match more than one album), and checks `canPerform(.addContent)` before adding.
- Stages downloads as complete-until-first-unlock (the default), never `complete`: a locked import inside a continued task then saves as it goes. A `complete` file fails while locked (`PHPhotosErrorDomain` 3302).
- Returns the `localIdentifier`, which the catalogue stores.
- Tested against a protocol, with a fake library in unit tests and the real one in the hardware plan.
- Decided by the spike: `.addOnly` can't create the album, so albums use read/write access (limited is enough).
- Open point: which albums. One per camera, one per import (dated), or both. The proposal has both, with the per-import album optional; Shamil asked for imports to go into a new album.
- Open point: iOS 27's `PHAssetCreationRequest.originalResourceChoice` picks whether the RAW or the JPEG is a pair's original. Decide which.

Could change with: the filenames and pair stems in the captured ObjectInfo fixtures; whether the card holds HEIF pairs; whether Apple's RAW decoder handles the α7C II's ARW (thumbnails fall back to the embedded JPEG either way).

## 6. Cameras, Browse and Import screens

SwiftUI with `@Observable` view models on the main actor, system (Liquid Glass) styling, as in the proposal's mockups.

Acceptance criteria:

- **Cameras:** the connected camera with a USB-C badge, and battery and card free space when the camera reports them. The empty state explains the cable and the USB mode, using the α7C II's exact menu wording from the findings.
- **Browse:** the card newest first in a lazy grid with day headers; RAW, HEIF and *already imported* badges; filters for new only, date range and type (video hidden by default); multi-select, *Select all new*, and a sticky bar with the count and size of the selection. The first screen of thumbnails appears ≤ 1 s after listing.
- **Import:** per-file rows with progress, throughput and ETA; pause, resume and cancel; files added from Browse land at the end.
- VoiceOver labels on the grid (filename, date, type, imported state); Dynamic Type up to the largest accessibility size; strings in a String Catalog.
- Goal 1 of the proposal: card contents visible within 5 s of plugging in, newest first, with thumbnails.

Could change with: the USB mode wording (empty-state copy); `usb.thumb.avg` and the thumbnail route; whether DeviceInfo lists BatteryLevel (0x5001); `usb.event.objectAdded` (whether Browse can update live).

## 7. PTPSimulator v1

A fake camera for the integration suite, depending on `PTPKit` only.

Acceptance criteria:

- Serves a scripted card (N objects with sizes, dates and formats, including RAW+JPEG pairs) over PTP/IP on loopback, with a `Network.framework` listener, using PTPKit's responder encoders and dataset initialisers.
- Answers `GetDeviceInfo`, `OpenSession`, `CloseSession`, `GetStorageIDs`, `GetStorageInfo`, `GetObjectHandles`, `GetObjectInfo`, `GetThumb`, `GetObject` and `GetPartialObject`, and can send `ObjectAdded`.
- Its `DeviceInfo` and `ObjectInfo` are seeded from the captured α7C II fixtures, so it answers like the camera.
- Runs in the iOS Simulator over loopback, so CI needs no camera.
- Open point: Iteration 1 has no `IPLink`, so the engine needs a way to reach the simulator, either a minimal test-only PTP/IP `CameraLink` (the spike's `PTPIPClient` is a starting point) or an in-process `CameraLink` over the scripted card. Faults (drops, slow link, duplicate filenames) come in Iteration 2.

Could change with: the fixtures it replays; the operations the camera actually lists in DeviceInfo; whether the camera supports `GetPartialObject` over PTP/IP.

## 8. CI on Xcode Cloud

Acceptance criteria:

- An Xcode Cloud workflow on every pull request: build the app, run every package's Swift Testing suite, the integration suite against `PTPSimulator` in the iOS Simulator, and the UI tests.
- The GitHub Actions checks from the spike ([ci.md](ci.md): `ptpkit.yml`, PTPKit on Linux; `spike-build.yml`, the Xcode 27 compile check) are kept for `PTPKit` and pointed at the workspace, or retired with the spike; decide when the workspace is created.
- A pull request merges only when every check is green.
- TestFlight builds of the production app are Iteration 2 (internal TestFlight on 15 Jan 2027); the hardware plan on the bench iPhone comes later.

Could change with: the multicast entitlement's status (the entitlement has to be on the App ID before any build that signs with it).
