# Spike findings

Spike 3–13 Nov 2026 · Shamil · Plan: [spike-plan.md](spike-plan.md) · How each step was run: [spike-runbook.md](spike-runbook.md)

Template, filled during the spike: the wired sections by day 5, the rest on day 10. Every value comes from the camera, the phone or the log; nothing is filled in ahead of the measurement.

## Setup

| Item | Value |
| --- | --- |
| iPhone model and iOS build (from the Log tab's Device section) | `iPhone18,4`, iOS 27.2 (24B119) |
| Spike app build | 0.1 (1.1), from TestFlight: built by the *Spike to TestFlight* workflow, run 1, with Xcode 27.1 from `main` at 2ca74cf. From 1 Nov 16:20: 0.1 (2.1), run 2, from `main` at d2851a7 (adds the Photos album test) |
| Camera model and firmware (`Fixtures/a7c2/usb/FIRMWARE`) | Sony Corporation ILCE-7CM2 (α7C II), firmware 2.0 (GetDeviceInfo over USB, 1 Nov). The serial number is in DeviceInfo and in `usb/deviceinfo.bin`; it is deliberately not written here. |
| Card (type, number of files by kind) | _to fill_ |
| Cable | _to fill_ |
| Camera access point band and channel | _to fill_ |
| Home LAN (SSID band, access point model) | _to fill_ |

## Go/no-go questions

One section per row of the plan's go/no-go table. The measurement names are the ones the spike app records (see the runbook).

### Wired import is viable

Go if `ImageCaptureCore` enumerates the card in some USB mode and sustains ≥ 25 MB/s. Otherwise stop: the product has no sanctioned transport on iPhone.

Measurements: `usb.catalog.complete`, `usb.catalog.count`, `usb.download.throughput.serial`, `usb.download.memory.peak`.

**Finding:** **Go.** In *Image Transfer (MTP)* mode, ImageCaptureCore lists the card and downloads 20 ARW (839 MB) at **38.19 MB/s** one at a time and **39.05 MB/s** two at a time, on a USB 2 iPhone. That is about 80 % of USB 2's 480 Mb/s, so the cable is the limit and a second download in flight gains nothing. 20 JPG (440 MB) come at **25.61 MB/s**: smaller files pay a fixed cost per file. Memory peaks at 70 MB, 3 MB over the 67 MB baseline, so downloads stream to disk. The weak point is listing: ImageCaptureCore takes **65 s** for 391 files in MTP mode. Build 3 times listing the card over PTP and in one MTP request instead.

**MSC mode is faster on every count** (same card, 19:45). Listing takes **7.17 s** against 65 s. ARW runs at **39.89 MB/s** one at a time and **41.73 MB/s** two at a time. JPG runs at **41.66 MB/s** against 25.61: a 24.8 MB JPG takes 0.58 s instead of 0.93 s, so MTP's fixed cost per file is gone. Memory peaks at 71 MB. But in MSC the camera answers no PTP commands: no GetPartialObject for resume, no events, and no GetThumb. Whether ImageCaptureCore's `requestReadData` at an offset gives MSC a resume of its own is a day-4 question. Which mode the product should prefer waits for build 3's PTP and MTP listing times.

**Evidence:** Log, 1 Nov 2026 19:43, build 0.1 (2.1), MTP: `usb.download.throughput.serial` 38.19 MB/s (20 of 20, 839.0 MB in 21.97 s); `usb.download.throughput.parallel2` 39.05 MB/s (839.0 MB in 21.49 s); `usb.download.jpg.throughput` 25.61 MB/s (439.5 MB in 17.16 s); `usb.download.memory.peak` 70.04 MB; `usb.catalog.complete` 64.96 s, 391 files. Full measurements under "Measurements".

### Byte-range resume on USB

Go if `GetPartialObject` works through `requestSendPTPCommand`. Otherwise resume per file only (restart the interrupted file), noted in the engine design.

Measurements: `usb.getPartialObject.supported`, `usb.getPartialObject.sha256Match`, `usb.getPartialObject.throughput`, `usb.resume.verified`. Fixture: `Fixtures/a7c2/usb/getpartialobject-<filename>.sha256`.

**Finding:** _to fill_

**Evidence:** _to fill_

### Wireless browsing in 1.0

Go if a camera mode lists on-card objects over PTP/IP and sustains ≥ 8 MB/s on the camera AP. Otherwise wireless in 1.0 becomes the camera-side *Send to Smartphone* flow, and full browsing moves to 1.1.

Measurements: `ptpip.ap.enumerate`, `ptpip.ap.objects`, `ptpip.ap.getObject.throughput`, and the LAN equivalents. See also the day-6 mode matrix below.

**Finding:** _to fill_

**Evidence:** _to fill_

### SSDP discovery

Go if the entitlement is granted and the camera announces. Otherwise typed IP and mDNS only; revisit when the entitlement lands.

Measurements: `ptpip.<net>.discovery.ssdp` (unicast or multicast, named in its context), `ptpip.<net>.discovery.bonjour`. Fixtures: `Fixtures/a7c2/ptpip/ssdp-description.xml`; what the Mac's SSDP capture showed is written here (the pcaps stay on the Mac, out of the repo).

**Finding:** _to fill_

**Evidence:** _to fill_

### Transfer-while-shooting feasible later

Go if `ObjectAdded` arrives on at least one link. Otherwise remove it from the post-1.0 list.

Measurements: `usb.event.objectAdded`, `ptpip.ap.event.objectAdded`, `ptpip.lan.event.objectAdded`. Fixtures: `event-objectadded.bin` in `usb/` and `ptpip/`.

**Finding:** _to fill_

**Evidence:** _to fill_

### Proximity reminder in 1.0

Go if the camera advertises a stable service UUID, at least while on, that iOS background scanning can filter on. Otherwise the reminder works only with the camera switched on, or falls back to a Shortcuts automation on the home Wi-Fi SSID.

Measurements: `ble.advert.<on/asleep/off>.<pairing>.seen`, `ble.connected.<state>.<pairing>.seen`, `ble.proximity.latency`, `ble.proximity.detectToNotify`, `ble.proximity.connectionEvent.latency`. Fixtures: `Fixtures/a7c2/ble/advert-*.json`.

**Finding:** _to fill_

**Evidence:** _to fill_

## Open questions from the proposal

| Question | Answer | Evidence |
| --- | --- | --- |
| Which USB connection mode gives `ImageCaptureCore` a session: *Still Img Transfer (MTP)* alone, or also *Select on Connect*? | With the camera asking on connection (*Select USB Connect Mode*), choosing **Image Transfer (MTP)** or **Image Transfer (MSC)** gives a session that lists the card. *Remote Shoot (PC Remote)* enumerates; a session there is untried. *Live Stream* doesn't enumerate. | 1 Nov, Wired tab and log |
| Does the camera emit `ObjectAdded` over USB while in MTP mode, or only in PC Remote mode? | **MTP: not advertised.** DeviceInfo lists three events only: StoreAdded, StoreRemoved and DevicePropChanged; neither ObjectAdded 0x4002 nor Sony's 0xC201. PC Remote mode is still to check (day 4's 60 s watch, in that mode). | GetDeviceInfo, 1 Nov 19:25, MTP |
| Is the PTP/IP initiator GUID remembered across camera power cycles, or does every connection need re-pairing on the camera? |  |  |
| Real throughput on the base-model (USB 2) iPhone with a UHS-II card in the camera |  |  |

## α7C II menu wording

The plan's paths use the α7 IV-generation names. Record what the α7C II actually shows.

| Plan's path | Used for | Observed wording |
| --- | --- | --- |
| `Setup → Setup Option → Version` | Firmware check |  |
| `Setup → USB → USB Connection Mode` | Choosing the USB mode |  |
| … *Select on Connect* | USB mode candidate | On plugging in, the camera shows **Select USB Connect Mode** with four choices (1 Nov), so a select-on-connect setting is in use. Its name in the menu is not yet recorded. |
| … *Still Img Transfer (MTP)* (older naming *MTP*) | USB mode candidate | **Image Transfer (MTP)** |
| … *Remote Shoot (PC Remote)* | USB mode candidate | **Remote Shoot (PC Remote)** |
| (not in the plan) | USB mode | **Image Transfer (MSC)**: mass storage |
| … *Webcam* | USB mode candidate | **Live Stream (USB Streaming)** |
| `Setup → USB → USB LUN Setting` | USB |  |
| `Setup → USB → USB Power Supply` | Battery test (set to Off) |  |
| `Network → Wi-Fi → Wi-Fi Connect` | Joining a network |  |
| `Network → Wi-Fi → Access Point Set.` | Registering the home SSID |  |
| `Network → Wi-Fi → Wi-Fi Frequency Band` | Forcing 5 GHz |  |
| `Network → Cnct./PC Remote → Smartphone Connect` | QR code, SSID and password |  |
| `Network → Cnct./PC Remote → PC Remote Function` | PC Remote over Wi-Fi |  |
| … *PC Remote Cnct Method* = *Wi-Fi Direct* | Day-6 mode |  |
| … *PC Remote Cnct Method* = *Wi-Fi Access Point* | Day-6 mode |  |
| … *Pairing* | PC Remote pairing |  |
| `Network → Transfer/Remote → Select on Camera & Send` | *Send to Smartphone*, the wireless fallback |  |
| *Bluetooth Function* (path not given in the plan) | BLE capture |  |
| *Remote Power ON/OFF* (path not given in the plan) | BLE capture while powered off |  |

## Measurements

Paste the output of the Log tab's *Copy measurements table* over this table; it adds "All measurements" and "Device" sections below it.

| Measurement | USB-C (USB 2 iPhone) | Wi-Fi, camera AP | Wi-Fi, UniFi LAN |
| --- | --- | --- | --- |
| Time to enumerate 200 files | 391 files: MTP 64.96 s; MSC 7.17 s (12.23 s on the first MSC run) |  |  |
| Thumbnail fetch, average per item | MTP 144.8 ms; MSC 187.6 ms |  |  |
| ARW throughput, single file | MTP 38.19 MB/s; MSC 39.89 MB/s |  |  |
| ARW throughput, two in flight | MTP 39.05 MB/s; MSC 41.73 MB/s | n/a (one transaction per PTP/IP session) | n/a (one transaction per PTP/IP session) |
| MP4 throughput (1 GB clip) | skipped for now (Shamil, 1 Nov) | skipped for now | skipped for now |
| `GetPartialObject` supported | advertised (0x101B, 32-bit); not yet exercised |  |  |
| Resume after link drop verified |  |  |  |
| `ObjectAdded` event received |  |  |  |
| Session survives phone lock (seconds) |  |  |  |
| Camera battery used per 1 GB |  |  |  |
| BLE: advertises when on / asleep / off; service UUID |  |  |  |

All measurements, MTP, from *Copy measurements table* (1 Nov 2026 19:43; the log had been cleared after the thumbnail runs, whose figures are in the table above):

| Name | Latest value | Unit | Count | Latest context |
| --- | --- | --- | --- | --- |
| `usb.catalog.complete` | 64.96 | s | 1 | open request → complete catalogue, 391 files |
| `usb.catalog.count` | 391.00 | files | 1 | mediaFiles; contents tree has 0 files; walk 0.6 ms |
| `usb.download.file` | 26.65 | MB/s | 60 | DSC01925.JPG 24.8 MB in 0.93 s, 20 newest JPG, serial [foreground] |
| `usb.download.jpg.throughput` | 25.61 | MB/s | 1 | 20 of 20 files, 439.5 MB on disk in 17.16 s, 1 in flight |
| `usb.download.memory.peak` | 70.04 | MB | 3 | baseline 67 MB, 20 newest JPG, serial |
| `usb.download.throughput.parallel2` | 39.05 | MB/s | 1 | 20 of 20 files, 839.0 MB on disk in 21.49 s, 2 in flight |
| `usb.download.throughput.serial` | 38.19 | MB/s | 1 | 20 of 20 files, 839.0 MB on disk in 21.97 s, 1 in flight |
| `usb.openSession` | 0.03 | s | 1 | ILCE-7CM2 |

Device: iPhone18,4; iOS 27.2 (24B119); spike 0.1 (2.1); Low Power Mode off; thermal nominal.

All measurements, MSC (1 Nov 2026 19:45, same device and build):

| Name | Latest value | Unit | Count | Latest context |
| --- | --- | --- | --- | --- |
| `usb.catalog.complete` | 7.17 | s | 1 | open request → complete catalogue, 391 files |
| `usb.catalog.count` | 391.00 | files | 1 | mediaFiles; contents tree has 391 files; walk 0.5 ms |
| `usb.download.file` | 42.57 | MB/s | 60 | DSC01925.JPG 24.8 MB in 0.58 s, 20 newest JPG, serial [foreground] |
| `usb.download.jpg.throughput` | 41.66 | MB/s | 1 | 20 of 20 files, 439.5 MB on disk in 10.55 s, 1 in flight |
| `usb.download.memory.peak` | 71.03 | MB | 3 | baseline 68 MB, 20 newest JPG, serial |
| `usb.download.throughput.parallel2` | 41.73 | MB/s | 1 | 20 of 20 files, 839.0 MB on disk in 20.11 s, 2 in flight |
| `usb.download.throughput.serial` | 39.89 | MB/s | 1 | 20 of 20 files, 839.0 MB on disk in 21.03 s, 1 in flight |
| `usb.openSession` | 0.03 | s | 1 | Untitled |

## Day-6 mode matrix

One row per camera mode. Note in the last column when the Mac (`gphoto2`, `nmap`, `tcpdump`) and the iPhone (Wi-Fi tab) disagree, and whether the card listing shows on-card objects or only tethered captures.

| Camera mode | SSDP | Port 15740 open | Handshake accepted | Card listed | Notes |
| --- | --- | --- | --- | --- | --- |
| Smartphone Connect |  |  |  |  |  |
| PC Remote over Wi-Fi Direct |  |  |  |  |  |
| PC Remote over Access Point |  |  |  |  |  |

## PTP/IP and join facts

| Question | Finding | Evidence |
| --- | --- | --- |
| What the camera shows on the first connection from the iPhone |  |  |
| GUID persistence after a power cycle (no prompt / prompt once / prompt every time) |  |  |
| What the camera shows for a new GUID |  |  |
| Operations listed in DeviceInfo over PTP/IP, compared with USB |  |  |
| Sony SDIO connect: response codes and whether the operation list changes |  |  |
| Camera's IP address on its own access point |  |  |
| Phone's internet while joined to the camera's access point (`NWPath`) |  |  |
| QR code format and the fields it holds (names only, never values) |  |  |
| Join flow: system sheets and prompts seen, and `ptpip.ap.join` |  |  |
| When the Local Network prompt appeared |  |  |

## BLE advertisement

With Bluetooth Function on and Remote Power ON/OFF on. Interval is the median gap between scan callbacks, so an upper bound.

| Camera power | Advertises | Service UUIDs | Manufacturer data | Interval | Seen from the next room |
| --- | --- | --- | --- | --- | --- |
| On |  |  |  |  |  |
| Asleep |  |  |  |  |  |
| Off |  |  |  |  |  |

By pairing context (the setup with Creators' App paired on the same iPhone):

| Pairing context | Advertises (on / asleep / off) | Connected to the system (`ble.connected.<state>.<pairing>.seen`) | Connection event received | Notes |
| --- | --- | --- | --- | --- |
| Creators' App connected |  |  |  |  |
| Creators' App quit, link down |  |  |  |  |
| Not paired |  |  |  |  |

Proximity filter UUID chosen: _to fill_

Proximity test:

| Scenario | Detected after (`ble.proximity.latency`) | Reminder posted after (`ble.proximity.detectToNotify`) | Connection event after (`ble.proximity.connectionEvent.latency`) | Notes |
| --- | --- | --- | --- | --- |
| Phone locked, same room |  |  |  |  |
| Phone locked, next room |  |  |  |  |
| Creators' App connected |  |  |  |  |
| Creators' App quit |  |  |  |  |
| After *Kill app to test relaunch* |  |  |  |  |

## ImageCaptureCore facts

| Question | Finding | Evidence |
| --- | --- | --- |
| USB connection mode(s) that enumerate in `ICDeviceBrowser`, and the ones Photos imports from | **Three of the four enumerate.** *Image Transfer (MTP)* and *Remote Shoot (PC Remote)*: `ILCE-7CM2`, `ICTransportTypeUSB`, 1 capability. In MTP: `kind=Camera`, `type=0x101`, USB `054C:0E8B` (Sony), the one capability is `ICCameraDeviceCanAcceptPTPCommands` (`acceptsPTPCommands=yes` before and after opening), the session opens in 0.04 s, but **the catalogue stayed at 0 %, 0 files, for at least 35 s** (1 Nov 19:03:09–19:03:46), then listed **391 files: 231 ARW (9,846.9 MB) and 160 JPG (3,433.4 MB)**. **Clean run, app in front: `usb.openSession` 0.03 s, `usb.catalog.complete` 64.82 s** (0 % throughout, then all 391 at once, with `ICCameraDeviceSupportsHEIF` added as it completed). In MTP `mediaFiles` has 391 files but the `contents` tree has none (in MSC both have 391). (First run 19:03–19:05; clean run 19:18:29–19:19:34.) Thumbnails, 50 newest: **144.8 ms average** (min 29.3, max 301.2), 50 of 50, about 6 KB JFIF each, run 1. Both miss day 2's targets (200 files listed in ≤ 2 s, thumbnails ≤ 50 ms). The device UUID embeds a 12-character hex string that looks like the camera's USB serial. *Image Transfer (MSC)*: `Untitled` (the card's volume), `ICTransportTypeMassStorage`, 2 capabilities; the card also mounts in the Files app as *Untitled* › `DCIM/100MSDCF` (391 items on 1 Nov, two files per frame with the same name, about 44–48 MB and 22–26 MB). In MSC: `kind=Camera`, `type=0x101`, USB `0000:0000`; capabilities `ICCameraDeviceCanDeleteOneFile` and `ICCameraDeviceCanAcceptPTPCommands` (`acceptsPTPCommands=yes`), plus `ICCameraDeviceSupportsHEIF` 5 s after opening. The session opens in 0.00 s; **`usb.catalog.complete` 12.23 s for 391 files** (0 % for about 4 s, then 40 → 387 files in 6 s); the `mediaFiles` and `contents` counts agree; handles are 0, as expected for mass storage. **Thumbnails, 50 newest: 187.56 ms average** (min 14.9, max 646.2), about 7 KB. **The PTP flag is misleading in MSC:** GetDeviceInfo and GetStorageIDs got no reply in 60 s, and GetObjectHandles none in 120 s. The product must decide by transport type, not by `acceptsPTPCommands`. (Log 1 Nov 19:09–19:17.) *Live Stream (USB Streaming)*: not seen. **Photos:** Import appears but lists nothing with a RAW-only card; the cause is not yet known (Photos hiding ARW, or no files presented). | Wired tab screenshots, 1 Nov 18:55–18:59 |
| Device type mask that finds the camera (*Cameras, local*, *Cameras* or *System default*) | *Cameras, local* (mask in use 0x101) finds it in MTP, PC Remote and MSC. | Wired tab, 1 Nov |
| Contents and control authorisation on iOS 27: prompt shown, and the status returned | **No prompt** on iOS 27.2; both statuses return `authorized` (`contents=authorized control=authorized`). | Wired tab, 1 Nov; Shamil |
| Pass-through reply layout (`PTPPassThrough.Layout`) and whether transaction IDs are renumbered | **`dataThenResponse`**: the first value is the bare data phase (8 B for GetStorageIDs), the second the 12-byte response container. **Transaction IDs are renumbered**: the response carried 801 for our 1. | Log 1 Nov 19:19:37, MTP |
| `GetObjectHandles` allowed through `requestSendPTPCommand` | **Yes: 397 handles in 0.03 s** (ImageCaptureCore lists 391 files; the rest are folders or objects it hides). None matches an `ICCameraFile.ptpObjectHandle`, because they are all 0. GetStorageIDs gives one store, 0x00010001 *Storage Media*, no label: 255.94 GB, 242.57 GB free, free images 0xFFFFFFFF, storage type 4 (removable RAM), filesystem 2 (generic hierarchical), access 1 (read-only, no deletion). Fixtures on the phone: `usb/storageids.bin` (8 B), `usb/storageinfo.bin` (56 B), `usb/objecthandles.bin` (1,592 B). | Log 1 Nov 19:19:37–19:19:41, MTP |
| `GetPartialObject` variant that works (0x101B, 0x95C1 or neither) | **Advertised in MTP: 0x101B (32-bit) yes; 0x95C1 no; Sony 0x9211 no.** So byte ranges work below 4 GiB only; a larger file would have to be fetched whole. Day 4's partial read will show whether it really works. | GetDeviceInfo, 1 Nov 19:25, MTP |
| `ObjectAdded` over USB: which code, delivered through `ptpEventHandler` or the delegate |  |  |
| Session survival on phone lock and app switch (seconds) |  |  |
| `BGContinuedProcessingTask`: start latency, how long it ran, whether the system expired it, the system progress UI | **Camera-free timer test, 2 minutes, 1 Nov, Low Power Mode on:** the task started 0.03 s after the request, ran 136.25 s through a phone lock and finished; the system did not expire it. It finished while the app was still in the background, 9 s before the app returned to the foreground. While the task ran, the app logged lock and unlock events from the background; with no task (the earlier plain-background run) the suspended app logged none. So the process really kept running. In the background the half-second sleeps took about 0.57 s each on average (240 steps in 136 s instead of 120 s). Progress UI: the system showed its progress circle as a Live Activity (Shamil, on the phone). **10 minutes, same day, Low Power Mode off (status bar):** started 0.02 s after the request, ran 675.62 s and finished; the system did not expire it. The app stayed in the background for the whole run (853.7 s in all), while the phone was locked and unlocked several times. The steps again averaged about 0.56 s. Still to run: longer than 10 minutes (a full card over USB 2 takes longer), and around a real USB download (day 5). | Log, 1 Nov 15:08:05–15:10:30: `bgcontinued.startLatency` 0.03 s; `bgcontinued.ran` 136.25 s, finished=true expired=false; app in the background 142.4 s, locked 134.6 s. Log, 1 Nov 15:26:42–15:40:58: `bgcontinued.startLatency` 0.02 s; `bgcontinued.ran` 675.62 s, finished=true expired=false; app in the background 853.7 s |
| `requestDownload` completion string: file name or path |  |  |
| `deviceDidBecomeReady(withCompleteContentCatalog:)` on a reopen of the same device |  |  |
| `ICCameraDevice.batteryLevel` compared with PTP BatteryLevel (0x5001) |  |  |
| `ICCameraItem.ptpObjectHandle` on iOS 27.2 (MTP; not in the plan) | **0 for every file** (the 5 newest logged). Day 4's ObjectInfo, partial read and resume steps can't take the handle from ImageCaptureCore, so they have to find it with `GetObjectHandles` and `GetObjectInfo`. | Log 1 Nov 19:05:19: `handle 0x00000000` on DSC02014–02018.ARW |
| DeviceInfo in MTP mode (not in the plan) | PTP 1.00; vendor extension 0xFFFFFFFF (plain MTP, no Sony extension), functional mode 0. **24 operations:** OpenSession, CloseSession, GetDeviceInfo, GetStorageIDs, GetStorageInfo, GetNumObjects, GetObjectHandles, GetObjectInfo, GetObject, **GetThumb 0x100A**, GetDevicePropDesc, GetDevicePropValue, 0x1016 SetDevicePropValue, **GetPartialObject 0x101B**, MTP 0x9801–0x9803 and **0x9805 GetObjectPropList** (one call can return every object's name, size and date), and 0x9280–0x9285 (unnamed). **Device properties (5):** 0x5001 BatteryLevel, 0xD402 DeviceFriendlyName, 0xD406 SessionInitiatorVersionInfo, 0xD407 PerceivedDeviceType, 0xD303. **Capture formats:** none. **Image formats (10):** 0x3001 Association, 0x300B, 0x3801 EXIF/JPEG, 0xB982 MP4, 0xB301 Sony MPO, 0x3000 Undefined, 0xB101 Sony ARW, 0xB310, 0x3008, 0xB110 Sony HEIF. Fixtures on the phone: `usb/deviceinfo.bin` (247 B, contains the serial), `usb/FIRMWARE` (14 B). | GetDeviceInfo, 1 Nov 19:25 |
| `ICDeviceBrowser` when the app goes to the background (not in the plan) | Logs *will suspend operations* on going to the background and *cancelled suspending operations* on return (no continued task running). Day 5 shows whether a continued task keeps it going. | Log 1 Nov 19:03:36, 19:03:45, 19:07:22, 19:07:36 |

## Photos albums

Not in the plan; added on 1 Nov because every import should go into an album. Steps: [spike-runbook.md](spike-runbook.md), "Photos albums".

| Question | Finding | Evidence |
| --- | --- | --- |
| Add-only: save a photo (A2) | Works: saved in 0.2 s, no further prompt (1 Nov, build 0.1 (2.1)). | Log 18:34:00: `save a test photo, no album → saved … · 0.2 s · access add-only allowed, read/write not asked` |
| Add-only: create an album holding the photo in one change block; did a read/write prompt appear? (A3) | **Yes: creating the album brought up the full read/write prompt**, 0.6 s into the step, and the change block waited for the answer. *Allow Full Access* was chosen, so the photo was saved into the new album (1.7 s in all). What happens after *Don't Allow* (does the photo still save without the album?) is still to test. | Log 18:34:05–06: `app went inactive during "save a test photo into a new album…" at +0.6 s`; `saved … into new album … · 1.7 s · access add-only allowed, read/write not asked → add-only allowed, read/write allowed` |
| Add-only: find the album after a relaunch, by identifier and by title (A4) | Not yet tested under add-only, because full access was granted in A3. Under full access, without a relaunch: found by identifier and by title, accepts new photos, and the save into it worked in 0.2 s. | Log 18:34:08 |
| Limited: create an album; find it after a relaunch (L2) | **Works, with no prompt.** With *Limited Access* and no photos selected, the album was created holding the photo (0.2 s). After a cold relaunch it was found by identifier (1) and by title (2: the album created earlier under full access is visible too), accepted new photos, and the save into it worked (0.2 s). | Log 18:41:06 and 18:41:22 (relaunch at 18:41:18): `access add-only allowed, read/write limited` |
| Locked, inside a continued task: A1, complete-until-first-unlock file, no album (K1, K2) | **K1, full access: saved in 0.1 s, locked at both ends.** The saves ran about 26 s after the lock. | Log 18:34:53.276: `locked save A1 … OK … · 0.1 s · locked at start yes, at end yes · task stopped or expired no` |
| Locked: A2, the same file class, into the test album (K1, K2) | **K1, full access: saved and added to the album in 0.1 s, locked at both ends.** | Log 18:34:53.374 |
| Locked: B, complete file, no album (K1, K2) | Failed, as expected: PHPhotosErrorDomain 3302 in 0.0 s, locked at both ends. A file with "complete" protection can't be read while the phone is locked, so imports must stage files as complete-until-first-unlock (the default). | Log 18:34:53.398 |
| Locked: find the album (K1) | K1, full access: found by identifier and by title while locked, accepts new photos, 0.0 s. | Log 18:34:53.412. The continued task ran 36.71 s and finished; start latency 0.02 s. `isProtectedDataAvailable` turned false about 10 s after the lock notification (lock at 18:34:26.9, detected 19 s after the 18:34:16.7 start), as Apple's security guide describes for *Require Passcode: Immediately*. |
| Access level the product needs for an album per import | **Read/write, but *Limited Access* with no photos selected is enough.** Add-only can't create an album without bringing up the read/write prompt. Limited access creates, finds and adds to the app's own albums, and saved photos join the limited selection by themselves. Look the album up by its stored identifier: the title can match more than one album. Settings on iOS 27.2 doesn't offer *Add Photos Only* for this app once it has asked for read/write (Shamil), so the declined-prompt case can only be tested on a fresh install. | A3, L2 |

## Multicast entitlement

| Item | Value |
| --- | --- |
| Request submitted on | _to fill_ |
| Reference | _to fill_ |
| Status on 13 Nov 2026 | _to fill_ |
| Key enabled in `Spike/Spike.entitlements` | _to fill_ |

## Go/no-go decision record

| Item | Value |
| --- | --- |
| Decided on | _to fill_ |
| Decided by | _to fill_ |
| Wireless scope for 1.0 | _to fill_ |

| Question | Result | Numbers behind it |
| --- | --- | --- |
| Wired import is viable |  |  |
| Byte-range resume on USB |  |  |
| Wireless browsing in 1.0 |  |  |
| SSDP discovery |  |  |
| Transfer-while-shooting feasible later |  |  |
| Proximity reminder in 1.0 |  |  |

Changes made to [proposal.md](proposal.md) (transport table, performance budget, roadmap): _to fill_

Iteration 1 backlog finalised ([iteration-1-backlog.md](iteration-1-backlog.md)): _to fill_
