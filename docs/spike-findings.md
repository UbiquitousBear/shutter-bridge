# Spike findings

Spike 3–13 Nov 2026 · Shamil · Plan: [spike-plan.md](spike-plan.md) · How each step was run: [spike-runbook.md](spike-runbook.md)

Template, filled during the spike: the wired sections by day 5, the rest on day 10. Every value comes from the camera, the phone or the log; nothing is filled in ahead of the measurement.

## Setup

| Item | Value |
| --- | --- |
| iPhone model and iOS build (from the Log tab's Device section) | `iPhone18,4`, iOS 27.2 (24B119) |
| Spike app build | 0.1 (1.1), from TestFlight: built by the *Spike to TestFlight* workflow, run 1, with Xcode 27.1 from `main` at 2ca74cf. From 1 Nov 16:20: 0.1 (2.1), run 2, from `main` at d2851a7 (adds the Photos album test) |
| Camera model and firmware (`Fixtures/a7c2/usb/FIRMWARE`) | _to fill_ |
| Card (type, number of files by kind) | _to fill_ |
| Cable | _to fill_ |
| Camera access point band and channel | _to fill_ |
| Home LAN (SSID band, access point model) | _to fill_ |

## Go/no-go questions

One section per row of the plan's go/no-go table. The measurement names are the ones the spike app records (see the runbook).

### Wired import is viable

Go if `ImageCaptureCore` enumerates the card in some USB mode and sustains ≥ 25 MB/s. Otherwise stop: the product has no sanctioned transport on iPhone.

Measurements: `usb.catalog.complete`, `usb.catalog.count`, `usb.download.throughput.serial`, `usb.download.memory.peak`.

**Finding:** _to fill_

**Evidence:** _to fill_

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

Measurements: `ptpip.<net>.discovery.ssdp` (unicast or multicast, named in its context), `ptpip.<net>.discovery.bonjour`. Fixtures: `Fixtures/a7c2/ptpip/ssdp-description.xml` and the Mac's SSDP pcaps.

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
| Which USB connection mode gives `ImageCaptureCore` a session: *Still Img Transfer (MTP)* alone, or also *Select on Connect*? |  |  |
| Does the camera emit `ObjectAdded` over USB while in MTP mode, or only in PC Remote mode? |  |  |
| Is the PTP/IP initiator GUID remembered across camera power cycles, or does every connection need re-pairing on the camera? |  |  |
| Real throughput on the base-model (USB 2) iPhone with a UHS-II card in the camera |  |  |

## α7C II menu wording

The plan's paths use the α7 IV-generation names. Record what the α7C II actually shows.

| Plan's path | Used for | Observed wording |
| --- | --- | --- |
| `Setup → Setup Option → Version` | Firmware check |  |
| `Setup → USB → USB Connection Mode` | Choosing the USB mode |  |
| … *Select on Connect* | USB mode candidate |  |
| … *Still Img Transfer (MTP)* (older naming *MTP*) | USB mode candidate |  |
| … *Remote Shoot (PC Remote)* | USB mode candidate |  |
| … *Webcam* | USB mode candidate |  |
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
| Time to enumerate 200 files |  |  |  |
| Thumbnail fetch, average per item |  |  |  |
| ARW throughput, single file |  |  |  |
| ARW throughput, two in flight |  |  |  |
| MP4 throughput (1 GB clip) |  |  |  |
| `GetPartialObject` supported |  |  |  |
| Resume after link drop verified |  |  |  |
| `ObjectAdded` event received |  |  |  |
| Session survives phone lock (seconds) |  |  |  |
| Camera battery used per 1 GB |  |  |  |
| BLE: advertises when on / asleep / off; service UUID |  |  |  |

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
| USB connection mode(s) that enumerate in `ICDeviceBrowser`, and the ones Photos imports from |  |  |
| Device type mask that finds the camera (*Cameras, local*, *Cameras* or *System default*) |  |  |
| Contents and control authorisation on iOS 27: prompt shown, and the status returned |  |  |
| Pass-through reply layout (`PTPPassThrough.Layout`) and whether transaction IDs are renumbered |  |  |
| `GetObjectHandles` allowed through `requestSendPTPCommand` |  |  |
| `GetPartialObject` variant that works (0x101B, 0x95C1 or neither) |  |  |
| `ObjectAdded` over USB: which code, delivered through `ptpEventHandler` or the delegate |  |  |
| Session survival on phone lock and app switch (seconds) |  |  |
| `BGContinuedProcessingTask`: start latency, how long it ran, whether the system expired it, the system progress UI | **Camera-free timer test, 2 minutes, 1 Nov, Low Power Mode on:** the task started 0.03 s after the request, ran 136.25 s through a phone lock and finished; the system did not expire it. It finished while the app was still in the background, 9 s before the app returned to the foreground. While the task ran, the app logged lock and unlock events from the background; with no task (the earlier plain-background run) the suspended app logged none. So the process really kept running. In the background the half-second sleeps took about 0.57 s each on average (240 steps in 136 s instead of 120 s). Progress UI: the system showed its progress circle as a Live Activity (Shamil, on the phone). **10 minutes, same day, Low Power Mode off (status bar):** started 0.02 s after the request, ran 675.62 s and finished; the system did not expire it. The app stayed in the background for the whole run (853.7 s in all), while the phone was locked and unlocked several times. The steps again averaged about 0.56 s. Still to run: longer than 10 minutes (a full card over USB 2 takes longer), and around a real USB download (day 5). | Log, 1 Nov 15:08:05–15:10:30: `bgcontinued.startLatency` 0.03 s; `bgcontinued.ran` 136.25 s, finished=true expired=false; app in the background 142.4 s, locked 134.6 s. Log, 1 Nov 15:26:42–15:40:58: `bgcontinued.startLatency` 0.02 s; `bgcontinued.ran` 675.62 s, finished=true expired=false; app in the background 853.7 s |
| `requestDownload` completion string: file name or path |  |  |
| `deviceDidBecomeReady(withCompleteContentCatalog:)` on a reopen of the same device |  |  |
| `ICCameraDevice.batteryLevel` compared with PTP BatteryLevel (0x5001) |  |  |

## Photos albums

Not in the plan; added on 1 Nov because every import should go into an album. Steps: [spike-runbook.md](spike-runbook.md), "Photos albums".

| Question | Finding | Evidence |
| --- | --- | --- |
| Add-only: save a photo (A2) | Works: saved in 0.2 s, no further prompt (1 Nov, build 0.1 (2.1)). | Log 18:34:00: `save a test photo, no album → saved … · 0.2 s · access add-only allowed, read/write not asked` |
| Add-only: create an album holding the photo in one change block; did a read/write prompt appear? (A3) | **Yes: creating the album brought up the full read/write prompt**, 0.6 s into the step, and the change block waited for the answer. *Allow Full Access* was chosen, so the photo was saved into the new album (1.7 s in all). What happens after *Don't Allow* (does the photo still save without the album?) is still to test. | Log 18:34:05–06: `app went inactive during "save a test photo into a new album…" at +0.6 s`; `saved … into new album … · 1.7 s · access add-only allowed, read/write not asked → add-only allowed, read/write allowed` |
| Add-only: find the album after a relaunch, by identifier and by title (A4) | Not yet tested under add-only, because full access was granted in A3. Under full access, without a relaunch: found by identifier and by title, accepts new photos, and the save into it worked in 0.2 s. | Log 18:34:08 |
| Limited: create an album; find it after a relaunch (L2) |  |  |
| Locked, inside a continued task: A1, complete-until-first-unlock file, no album (K1, K2) | **K1, full access: saved in 0.1 s, locked at both ends.** The saves ran about 26 s after the lock. | Log 18:34:53.276: `locked save A1 … OK … · 0.1 s · locked at start yes, at end yes · task stopped or expired no` |
| Locked: A2, the same file class, into the test album (K1, K2) | **K1, full access: saved and added to the album in 0.1 s, locked at both ends.** | Log 18:34:53.374 |
| Locked: B, complete file, no album (K1, K2) | Failed, as expected: PHPhotosErrorDomain 3302 in 0.0 s, locked at both ends. A file with "complete" protection can't be read while the phone is locked, so imports must stage files as complete-until-first-unlock (the default). | Log 18:34:53.398 |
| Locked: find the album (K1) | K1, full access: found by identifier and by title while locked, accepts new photos, 0.0 s. | Log 18:34:53.412. The continued task ran 36.71 s and finished; start latency 0.02 s. `isProtectedDataAvailable` turned false about 10 s after the lock notification (lock at 18:34:26.9, detected 19 s after the 18:34:16.7 start), as Apple's security guide describes for *Require Passcode: Immediately*. |
| Access level the product needs for an album per import | **Read/write, not add-only:** an add-only app gets the full prompt as soon as it creates an album. Whether *Limited Access* is enough is still to test (L2). |  |

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
