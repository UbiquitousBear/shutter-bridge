# Spike findings

Spike 3–13 Nov 2026 · Shamil · Plan: [spike-plan.md](spike-plan.md) · How each step was run: [spike-runbook.md](spike-runbook.md)

Template, filled during the spike: the wired sections by day 5, the rest on day 10. Every value comes from the camera, the phone or the log; nothing is filled in ahead of the measurement.

## Setup

| Item | Value |
| --- | --- |
| iPhone model and iOS build (from the Log tab's Device section) | `iPhone18,4`, iOS 27.2 (24B119) |
| Spike app build | 0.1 (1.1), from TestFlight: built by the *Spike to TestFlight* workflow, run 1, with Xcode 27.1 from `main` at 2ca74cf. From 1 Nov 16:20: 0.1 (2.1), run 2, from `main` at d2851a7 (adds the Photos album test). From 1 Nov evening: 0.1 (3.1), run 3, from `main` at bc867a1 (spike builds 3 and 4: handle lookup, PTP and MTP listing, serial kept out of the log). From 1 Nov 23:00: 0.1 (4.1), run 4, from `main` at 39231f1 (spike build 5: stops on a camera that has stopped answering). From 1 Nov 23:33: 0.1 (5.1), run 5, from `main` at 8580535 (spike build 6: per-object MTP listing, stall recovery, copyable log). From 2 Nov 01:38: 0.1 (6.1), from `main` at 9db1515 (spike build 8: the Guided tab). From 2 Nov 13:47: 0.1 (7.1), from `main` at d6d33a7 (spike build 9: Sony contents transfer over Wi-Fi). From 2 Nov 22:08: 0.1 (9.1), run 9, from `main` at 8e010ff (spike build 9.1: no battery read where the camera won't answer). From 3 Nov 00:04: 0.1 (11.1), run 11, from `main` at 7c4909f (spike build 10: the Bluetooth Wi-Fi handover experiment). From 3 Nov 11:33: 0.1 (12.1), run 12, from `main` at 994c3be (spike build 12: notification subscriptions before the Wi-Fi-on write, the Bluetooth join, copy all RAW to Files). From 3 Nov 14:56: 0.1 (13.1), run 13, from `main` at 3944ee9 (spike build 13: Bluetooth switches the camera's Wi-Fi on, then join and import). From 3 Nov 22:43: 0.1 (14.1), run 14, from `main` at 303a13f (spike build 14: the camera's Wi-Fi lifecycle, copy recovery and pause). TestFlight's build number is the workflow run, not the spike build. |
| Camera model and firmware (`Fixtures/a7c2/usb/FIRMWARE`) | Sony Corporation ILCE-7CM2 (α7C II), firmware 2.0 (GetDeviceInfo over USB, 1 Nov); over PTP/IP on 2 Nov DeviceInfo says 2.01. The serial number is in DeviceInfo and in `usb/deviceinfo.bin`; it is deliberately not written here. |
| Card (type, number of files by kind) | _to fill_ |
| Cable | _to fill_ |
| Camera access point band and channel | **5 GHz only** (Shamil, 3 Nov, from the camera's menu); channel not known. Over Bluetooth, CCAB reads `04 00 00 02 03` with the menu on 5 GHz (3 Nov 22:44, build 0.1 (14.1)); one menu setting, so the mapping is a single point. |
| Home LAN (SSID band, access point model) | _to fill_ |

## Go/no-go questions

One section per row of the plan's go/no-go table. The measurement names are the ones the spike app records (see the runbook).

### Wired import is viable

Go if `ImageCaptureCore` enumerates the card in some USB mode and sustains ≥ 25 MB/s. Otherwise stop: the product has no sanctioned transport on iPhone.

Measurements: `usb.catalog.complete`, `usb.catalog.count`, `usb.download.throughput.serial`, `usb.download.memory.peak`.

**Finding:** **Go.** In *Image Transfer (MTP)* mode, ImageCaptureCore lists the card and downloads 20 ARW (839 MB) at **38.19 MB/s** one at a time and **39.05 MB/s** two at a time, on a USB 2 iPhone. That is about 80 % of USB 2's 480 Mb/s, so the cable is the limit and a second download in flight gains nothing. 20 JPG (440 MB) come at **25.61 MB/s**: smaller files pay a fixed cost per file. Memory peaks at 70 MB, 3 MB over the 67 MB baseline, so downloads stream to disk. The weak point is listing: ImageCaptureCore takes **65 s** for 391 files in MTP mode. Build 3 times listing the card over PTP and in one MTP request instead.

**MSC mode is faster on every count** (same card, 19:45). Listing takes **7.17 s** against 65 s. ARW runs at **39.89 MB/s** one at a time and **41.73 MB/s** two at a time. JPG runs at **41.66 MB/s** against 25.61: a 24.8 MB JPG takes 0.58 s instead of 0.93 s, so MTP's fixed cost per file is gone. Memory peaks at 71 MB. But in MSC the camera answers no PTP commands: no GetPartialObject for resume, no events, and no GetThumb. Whether ImageCaptureCore's `requestReadData` at an offset gives MSC a resume of its own is a day-4 question. **Listing in MTP mode can't be made faster from the app** (build 6, 1 Nov 23:34–23:42):
- The camera takes about 165 ms per object for GetObjectInfo and about 385 ms for GetObjectPropList. One request for the whole card can't finish inside ImageCaptureCore's 60 s limit.
- ImageCaptureCore's own catalogue (65 s for 391 files) is already as fast as any listing the app can send.
- The app's pass-through commands wait until that catalogue has finished, so nothing over PTP, not even the newest file's thumbnail, can appear sooner.
- At this pace a 2,000-file card takes about 5½ minutes in MTP mode before anything shows, against seconds in MSC.

**On the evidence so far, MSC is the better wired mode:** listing is 9 × faster and JPG downloads are 60 % faster. MTP offers GetPartialObject, PersistentUniqueObjectIdentifier and GetThumb, which is no faster than ImageCaptureCore's thumbnails. Before deciding, two things are worth testing:
- whether `requestReadData` at an offset gives MSC a resume of its own;
- whether *PC Remote* mode, the only one with the shutter enabled, behaves like MTP.

**Evidence:** Log, 1 Nov 2026 19:43, build 0.1 (2.1), MTP: `usb.download.throughput.serial` 38.19 MB/s (20 of 20, 839.0 MB in 21.97 s); `usb.download.throughput.parallel2` 39.05 MB/s (839.0 MB in 21.49 s); `usb.download.jpg.throughput` 25.61 MB/s (439.5 MB in 17.16 s); `usb.download.memory.peak` 70.04 MB; `usb.catalog.complete` 64.96 s, 391 files. Full measurements under "Measurements".

### Byte-range resume on USB

Go if `GetPartialObject` works through `requestSendPTPCommand`. Otherwise resume per file only (restart the interrupted file), noted in the engine design.

Measurements: `usb.getPartialObject.supported`, `usb.getPartialObject.sha256Match`, `usb.getPartialObject.throughput`, `usb.resume.verified`. Fixture: `Fixtures/a7c2/usb/getpartialobject-<filename>.sha256`.

**Finding:** **Go: verified with a cable pull.** The same holds over Wi-Fi with Sony's 0x9211 (see *Wireless browsing in 1.0*).
- **The cable pull:** the newest ARW (DSC02018.ARW, 40.3 MB) was read with GetPartialObject in 1 MiB chunks, and the cable was pulled at 47 % (offset 18,874,368). The read failed at once with two empty pass-through values, ImageCaptureCore reported the removal 30 ms later, and the offset was saved.
- **The resume:** after a replug the app opened a new session. Once the 64.9 s catalogue was complete, it found the object again in one GetObjectInfo call (the handle, 0x00300123, is the same across a replug) and continued from the saved offset. The finished file matched a `requestReadData` copy by SHA-256.
- **Earlier the same night:** GetPartialObject 0x101B read the whole file at **37.29 MB/s**, 10.8 % below `requestDownload` of the same file, within the plan's 15 %. That reassembly matched both `requestReadData` (41.12 MB/s) and `requestDownload` (41.81 MB/s) by SHA-256.
- **Files of 4 GiB or more can't be read in ranges:** 0x101B takes 32-bit offsets and the camera advertises no 64-bit variant (0x95C1). Only a long MP4 can be that big, so an interrupted one restarts from the beginning.
- **ImageCaptureCore's own `requestReadData` also reads at an offset in MTP mode**, slightly faster than GetPartialObject. If it works in MSC mode too, it is MSC's resume path, which GetPartialObject can't be (no PTP in MSC). Build 7 adds that test.

**Evidence:**
- Log, 1 Nov 2026 23:47:37–23:49:19, build 0.1 (5.1), MTP:
  - "Resumable read interrupted at offset 18874368 of 40329216 (47 %)".
  - `usb.resume.verified` yes ("interrupted at 18874368 …, resumed at 18874368 in a new request sequence, SHA-256 match").
- Log 1 Nov about 23:00, build 0.1 (4.1):
  - `usb.getPartialObject.supported` yes.
  - `usb.getPartialObject.throughput` 37.29 MB/s.
  - `usb.getPartialObject.sha256Match` yes.
  - `usb.readData.throughput` 41.12 MB/s.
  - `usb.download.file` 41.81 MB/s.

### Wireless browsing in 1.0

Go if a camera mode lists on-card objects over PTP/IP and sustains ≥ 8 MB/s on the camera AP. Otherwise wireless in 1.0 becomes the camera-side *Send to Smartphone* flow, and full browsing moves to 1.1.

Measurements: `ptpip.ap.enumerate`, `ptpip.ap.objects`, `ptpip.ap.getObject.throughput`, and the LAN equivalents. See also the day-6 mode matrix below.

**Finding:** **Go.** On the camera's own network, *PC Remote* lists the whole card faster than USB and downloads ARW at **15.5 MB/s**, almost twice the 8 MB/s criterion.

*PC Remote* on the camera's own network lists the whole card once the session is opened Sony's way, as open-source ZV-E10 code (mvpzac/Imagedge) does it:
1. SDIO_OpenSession (0x9210) [1, 1] instead of OpenSession;
2. Sony's init sequence;
3. SDIO_SetContentsTransferMode (0x9212) [2,0,0], then [2,1,0].

The camera then announced its card with StoreAdded 0x00010001.

**The figures** (two runs on 2 Nov; the card grew from 391 to 419 files in between):
- **Listing:** 391 files in **4.74 s**, then 419 files (259 ARW, 160 JPG, 7 folders) in **4.95 s**. Over USB the 391-file card takes 65 s in MTP and 7.2 s in MSC; the plan's target is 200 files in 5 s or less.
- **Ready time:** the card was ready to list **2.6 s** after the switch, both times.
- **Thumbnails:** 50 at **38.7 ms** and **35.4 ms** each on average (slowest about 100 ms). Over USB they take 145–188 ms; the target is 50 ms or less.
- **Downloads:** 20 ARW (954 MB) at **15.5 MB/s**, from the first request to the last response. A second run (22:51, 944 MB) gave **11.7 MB/s**, with files at 6–8 MB/s while the link quality dipped. The camera's network gives 11.7–15.5 MB/s, above the criterion both times. Per file it rose from 12.2 MB/s (the first) to 15–17 MB/s; every file has a SHA-256. That is about 40 % of USB 2 (38–40 MB/s): 1 GB takes about 65 s over the camera's Wi-Fi against 26 s on the cable. Memory peaked at 65.5 MB (baseline 57 MB).

The camera reports the storage as "Storage Media 1", read-only without deletion (access capability 1), with its capacity shown as 0.

**What doesn't work:** a plain OpenSession, with or without the init sequence, still gets StoreNotAvailable (0x2013) from GetStorageIDs.

**One trap:** the session lists no device properties, and the camera never answers GetDevicePropValue. On build 9 the app's BatteryLevel (0x5001) read waited 30 s for a reply, the idle timeout ended the connection, and the first download never started. Build 9.1 reads only what DeviceInfo lists; production must do the same.

**After a drop and under lock** (guided runs, 2 Nov 22:24–22:28, build 0.1 (9.1)):
- **Reconnecting works and finds the same files.** After Wi-Fi was switched off and on, the app reopened the contents-transfer session in about 2.5 s, and the card listed again with the same handles: DSC02046.ARW was 0x400010A3 in every session. So a saved import can find its file again without a full relist.
- **Byte-range resume works, with Sony's own command.** Only Sony's SDIO_GetPartialLargeObject (**0x9211**) reads part of a file in this session. Its parameters are handle, offset low, offset high, length low, length high (a 64-bit offset and length).
  - Standard GetPartialObject (0x101B, three or four parameters) and 0x9219 answer InvalidObjectHandle.
  - A 1 MiB read at the start and one in the middle both matched a full download byte for byte.
  - Resume test (23:10): a read in 4 MiB chunks was cut at 54 % by switching Wi-Fi off. The app reconnected (the same handle, 0x40001103), resumed at the saved offset and finished. The SHA-256 matches the GetObject reference.
  - Chunked reads ran at 12.9 MB/s before the drop and 7.3 MB/s for the six chunks after it.
- **Locked without a continued task, the transfer stops and the session is lost.** Nothing downloaded in 123 s locked, and on return the connection had timed out. Over USB the session survived 227 s.
- **Locked inside a continued task, the transfer runs at full speed.** 20 ARW (954 MB) downloaded in 62.1 s (15.4 MB/s) entirely while locked, and the task finished without expiring. As over USB, every Wi-Fi import must run inside `BGContinuedProcessingTask`.
- **The reference download is repeatable.** DSC02046.ARW gave the same SHA-256 (763d068d7de5…) in two sessions 14 minutes apart.
- **Evidence for the resume:** guided run *Wi-Fi: resume after Wi-Fi off*, 2 Nov 23:10, build 0.1 (10.1). `ptpip.ap.partial.sonyLarge9211` yes; `ptpip.ap.partial.standard32`, `.sony64` and `.sonyLarge9219` no; `ptpip.ap.resume.verified` yes (DSC02052.ARW, SHA-256 13605b153d9a…).

**A whole card copied to Files over Wi-Fi** (guided run *Copy all RAW to Files*, 3 Nov, build 0.1 (13.1); the camera's network, whole-card contents transfer, inside `BGContinuedProcessingTask`, into the app's Documents folder; Shamil shoots RAW only):

| Run | Creators' App | Phone | Result |
| --- | --- | --- | --- |
| 15:13 | open in the background, connected over Bluetooth | locked for most of it | 7 of 267 copied. 28 s in, the camera sent StoreRemoved, refused the next GetObject with StoreNotAvailable, closed both channels and switched its Wi-Fi off. The copy wrongly counted the next 82 files as failed before the link closed. |
| 15:25 | quit | locked for 217 s of 271 s | 102 of 267 (4.32 GB) at 15.9 MB/s, no failures. iOS expired the continued task at 271 s, when Shamil opened the phone's Camera app. |
| 15:30 | quit | in the background, phone unlocked and in use (Files) | **267 of 267, 11.53 GB in 11.8 min at 16.3 MB/s, no failures.** The continued task ran 709 s without expiring. Every file opens in Files. |

- **A full card copies over Wi-Fi in about 12 minutes, in the background.** Files ran at 13–19 MB/s each; memory peaked at 68 MB (baseline 60 MB).
- **The camera's Wi-Fi is the limit, not the app or the phone.** Moving each file into place took about 0.01 s and the gap between files was small, so 16.3 MB/s (about 135 Mbit/s of data) is the link itself. The camera was on 5 GHz only; that rate fits a single-antenna camera on 5 GHz. The same card reads at 38–41 MB/s over USB, where the phone's USB 2 port is the limit.
- **Creators' App open in the background is the likely cause of the camera dropping its card and Wi-Fi.** It happened in both runs with Creators' App open (also at 11:54 during a Bluetooth switch-on) and in none of the runs with it quit. A later Bluetooth run with Creators' App open (22:43, about 4 minutes with three downloads; *BLE advertisement* below) had no drop, so it happens sometimes rather than every time. Not proven; 1.0 has to recover either way.
- **iOS can expire the continued task when the phone is busy with something heavy.** The 271 s expiry coincided with the Camera app; the run that kept going for 709 s had only Files in front. iOS gives no reason with an expiry. Apple documents expiry under resource pressure and for tasks that report little progress, and publishes no time limit.
- **What this means for 1.0:** the copy needs to recover when the camera drops its store or session (wait, reconnect, relist, resume at the file in flight), and to pause cleanly on expiry and carry on into the same folder when the app returns. Build 14 adds both, with progress reported in bytes rather than per file.

(The first run, 12:08, was labelled *Smartphone Connect* in the app, but the camera was in *PC Remote*. Shamil, 2 Nov: Smartphone Connect showed no QR code.)

**Listing time against card size (projected, 3 Nov).** The guided *Scaling* run (a burst of about 300 frames) was dropped; the projections come from the listings already made. Over Wi-Fi the card was listed nine times on 2–3 Nov at 397–435 handles in 4.74–7.30 s, so about **11–17 ms per handle**. The card grew too little across those runs to separate a fixed cost from a per-object cost, and run-to-run spread (4.97–7.30 s at the same size) exceeds the size effect, so the whole time is counted as per-object, which makes these upper bounds:

| Items on the card | Wi-Fi, whole-card session | USB, MSC (7.17 s for 391 files, about 18 ms each) | USB, MTP (165 ms per object) |
| --- | --- | --- | --- |
| 435 (3 Nov) | 5–7 s | about 8 s | about 72 s |
| 555 (3 Nov 22:44) | **7.3 s, measured** | about 10 s | about 1½ min |
| 2,000 | about 25–35 s | about 37 s | about 5½ min |
| 5,000 | about 1–1½ min | about 1½ min | about 14 min |

- **A second size point** (3 Nov 22:44, build 0.1 (14.1)): 555 handles (547 objects: 360 ARW, 187 JPG; 8 folders) listed in **7.32 s**, 13.2 ms per handle, inside the 11–17 ms range. The card was ready at the first poll (2.03 s, mostly the sequence's fixed waits), as at 432 handles. The spread at one size (4.97–7.30 s) is still as large as the change, so the projection stands.
- Each Wi-Fi item is one GetObjectInfo round trip, so the growth should be linear. The part not checked at a larger size is the camera indexing the card when the session opens (2 s for 432 handles; 0.1 s on a reopen).
- **It matters for the first import only.** Handles are stable across sessions (above), so 1.0 can keep what it has listed and ask only for new handles; a day's shooting then adds seconds.
- Later listings come for free as the card grows; each Wi-Fi run logs `ptpip.ap.enumerate`, and one more MSC listing at a larger size gives USB its second point.

**Still to run:**
- *PC Remote* over an access point (the home LAN).

**Dropped (Shamil, 3 Nov):**
- *Smartphone Connect*: the Bluetooth switch-on (*BLE advertisement* below) is the smartphone connection Creators' App uses, and it lists the whole card, so this row adds nothing.
- *Send to Smartphone*: the fallback for a camera that doesn't list its card over PTP/IP, which this one does.

**Evidence:** Guided run *Wi-Fi: one camera mode* › *PC Remote (camera's network)*, 2 Nov 13:47–13:49, build 0.1 (7.1):
- "SDIO_OpenSession (0x9210) [1, 1], ContentsTransfer: OK"; 0x9212 [2,0,0] OK and [2,1,0] OK; then the event "StoreAdded (0x4004) … [0x00010001]".
- `ptpip.ap.contentsTransfer.wholeCard.ready` 2.61 s (first poll: 397 handles); `ptpip.ap.contentsTransfer.wholeCard.lists` yes.
- `ptpip.ap.enumerate` 4.74 s, `ptpip.ap.objects` 391; `ptpip.ap.thumb.avg` 38.74 ms (50 thumbnails, 3,905 KB, 0 failed).
- "battery read failed: command channel: nothing received for 30 s", then "GetObject 20 newest ARW failed".
- Earlier the same day (12:08, build 0.1 (6.1)), a plain session got "GetStorageIDs answered StoreNotAvailable (0x2013)".

Guided run *Wi-Fi: one camera mode* › *PC Remote (camera's network)*, 2 Nov 22:08–22:11, build 0.1 (9.1):
- `ptpip.ap.contentsTransfer.wholeCard.ready` 2.55 s (426 handles); `ptpip.ap.enumerate` 4.95 s, `ptpip.ap.objects` 419 (ARW 259, JPG 160).
- `ptpip.ap.thumb.avg` 35.35 ms (50, slowest 98 ms, 0 failed).
- "BatteryLevel (0x5001) isn't in this session's DeviceInfo, so the battery isn't read".
- `ptpip.ap.getObject.throughput` 15.50 MB/s (20 ARW, 954.3 MB, 61.6 s); `ptpip.ap.getObject.file` 12.20 MB/s for the first, 14–17 MB/s for the rest; `ptpip.ap.download.memory.peak` 65.47 MB.

### SSDP discovery

Go if the entitlement is granted and the camera announces. Otherwise typed IP and mDNS only; revisit when the entitlement lands.

Measurements: `ptpip.<net>.discovery.ssdp` (unicast or multicast, named in its context), `ptpip.<net>.discovery.bonjour`. Fixtures: `Fixtures/a7c2/ptpip/ssdp-description.xml`; what the Mac's SSDP capture showed is written here (the pcaps stay on the Mac, out of the repo).

**Finding:** **The camera announces itself, and the phone heard it without the multicast entitlement.** On the camera's own network in *PC Remote*:
- **It sends SSDP announcements** (NOTIFY for `upnp:rootdevice`, `urn:schemas-upnp-org:device:Basic:1` and `urn:schemas-sony-com:service:DigitalImaging:1`) to the multicast group.
- **The spike received them anyway:** it has no `com.apple.developer.networking.multicast`, yet its `NWConnectionGroup` became ready and received them 0.73 s after joining.
- **Our own multicast M-SEARCH never went out:** both sends were still pending when the group closed 5 s later. The camera didn't answer a unicast M-SEARCH, and advertised no `_ptp._tcp` over Bonjour.

**What this means for 1.0:**
- On the camera's own network, discovery isn't needed: the camera is at 192.168.122.1.
- On the home network it is. If passive listening works there too, the app can find the camera without waiting for Apple's entitlement.

**Still to run:**
- the same listen on the home LAN, with the camera in *PC Remote* over an access point;
- the entitlement request (see *Multicast entitlement*).

**Evidence:** Guided run *Wi-Fi: one camera mode*, 2 Nov 12:13:47–12:13:58: "SSDP unicast to 192.168.122.1: no reply within 5 s"; "SSDP multicast group ready; M-SEARCH sent"; four NOTIFYs from 192.168.122.1, `ptpip.ap.discovery.ssdp` 0.73 s; at 12:13:58 "SSDP multicast M-SEARCH send failed: … Operation canceled" twice. `Spike/Spike.entitlements` has the multicast key commented out. Bonjour: "no _ptp._tcp service within 5 s".

The UPnP description at `http://192.168.122.1:64321/dd.xml` has:
- friendlyName `ILCE-7CM2`, manufacturer `Sony Corporation`, modelName `SonyImagingDevice`;
- no serialNumber;
- service `urn:schemas-sony-com:service:DigitalImaging:1`;
- vendor fields `X_ScalarWebAPI_DefaultFunction` = `RemoteShooting` and a live-view URL on port 60152.

**Keep the camera's hardware ID out of the repo.** The description's UDN ends in a 12-hex-digit ID, and the camera's PTP/IP responder GUID ends in the same ID (`…-FFFF-` and then those 12 digits). It looks like a MAC address and is not written here. `scripts/redact-fixtures.py` only zeroes serial numbers, so the phone's `ptpip/ssdp-description.xml` must have this ID redacted before it is committed.

### Transfer-while-shooting feasible later

Go if `ObjectAdded` arrives on at least one link. Otherwise remove it from the post-1.0 list.

Measurements: `usb.event.objectAdded`, `ptpip.ap.event.objectAdded`, `ptpip.lan.event.objectAdded`. Fixtures: `event-objectadded.bin` in `usb/` and `ptpip/`.

**Finding:** **Go, over Wi-Fi in *PC Remote*.** Pressing the camera's shutter sent Sony's ObjectAdded (0xC201) with handle **0xFFFFC001** about 0.4 s after the capture. The frame was also saved to the card (*Still Img. Save Dest.*: *Dest. + Camera*).
- **USB, MTP:** no. The mode advertises no ObjectAdded event and disables the shutter.
- **Wi-Fi, *PC Remote*, plain session after the init sequence:** yes.
  - 0xC223 reports the shutter's state: 5 when half-pressed, 7 at the capture, then 1.
  - A real shot went 5 → 7 → 1 → 0xC206, then 0xC201 [0xFFFFC001] (22:50:52). A second shot 1.5 s later sent another.
  - The two earlier "no" results (13:48 and 22:09) showed only 5 and 1, which fits a half-press without a capture. No new file reached the card in those tests.
- **What 0xFFFFC001 is:** the camera's buffer slot for the shot. Fetching the frame from it (GetObjectInfo/GetObject on 0xFFFFC001), or finding it on the card by name, is still to try. It isn't needed for 1.0.
- **Still to try:** *Remote Shoot (PC Remote)* over USB.

**Evidence:** GetDeviceInfo in MTP mode, 1 Nov 22:59:37: events StoreAdded, StoreRemoved and DevicePropChanged only; "ObjectAdded 0x4002 no · Sony ObjectAdded 0xC201 no". Shamil, 1 Nov: the shutter is disabled in MTP and MSC. Wi-Fi: guided run *Wi-Fi: one camera mode* › *PC Remote (camera's network)*, 2 Nov 22:50, build 0.1 (9.1): "Sony ObjectAdded (0xC201) … params [0xFFFFC001]", `ptpip.ap.event.objectAdded` yes. The next listing's newest file was DSC02052.ARW, captured 22:50:49 by the camera's clock. Shamil: one full press took a photo.

### Proximity reminder in 1.0

Go if the camera advertises a stable service UUID, at least while on, that iOS background scanning can filter on. Otherwise the reminder works only with the camera switched on, or falls back to a Shortcuts automation on the home Wi-Fi SSID.

Measurements: `ble.advert.<on/asleep/off>.<pairing>.seen`, `ble.connected.<state>.<pairing>.seen`, `ble.proximity.latency`, `ble.proximity.detectToNotify`, `ble.proximity.connectionEvent.latency`. Fixtures: `Fixtures/a7c2/ble/advert-*.json`.

**Finding:** **Go: both halves pass.** The camera advertises a stable service UUID in every power state, and a background scan filtered on it woke the locked phone and posted the reminder.
- **It advertises in every power state:** with Creators' App quit, the camera advertised on, asleep and switched off.
- **The same service UUID every time:** 1800, with Sony's company ID (0x012D) in the manufacturer data.
- **It keeps advertising when switched off**, as the proposal hoped. The reminder can therefore fire whenever the camera comes within range, which is what the proposal describes.
- **The power state can't be read from the advertisement:** the manufacturer data is identical on, asleep and off, so the reminder can say "nearby" but not "switched on".
- **The background scan works with the phone locked:** with the camera in the next room (RSSI -83 dBm), iOS reported it **11.76 s** after the scan was started, the reminder was accepted **0.02 s** later, and tapping it opened the app on the Wired tab.

**The catch: 1800 is not a Sony service.** It is Bluetooth's standard *Generic Access* service, so a background scan filtered on it can also wake the app for other devices that advertise it. After a wake, the app has to confirm the camera:
- by the peripheral identifier stored when the camera was linked (the same identifier in every scan, 683987C3…, as iOS assigns it to this app); or
- by Sony's company ID together with the name.

**What the design has to allow for:**
- **The trigger is coming into range, not switching on.** The camera advertises the same data while switched off, so a scan can't tell that it was switched on. The reminder fires when the phone and the camera come within range of each other, for example on getting home, whether the camera is on or off.
- **iOS mostly reports the camera once per scan while it stays in range.** Within one scan it was reported again around the first power-off (11:52:47 and, locked, 11:53:01), then not at all during 92 s and 130 s in the background. The spike restarts the scan 60 s after a discovery so the camera is reported afresh, but on a timer, which doesn't run while the app is suspended: in this run every restart happened when the app came back to the front. Production has to restart the scan from a wake (a discovery, a connection event, a background refresh) instead of a timer, without letting a camera that sits in range wake the app over and over.
- **Hold the reminder while the app is connected or importing.** During the locked Wi-Fi import (2 Nov 22:28) the continued task kept the app running, the scan restarted, and the camera being imported from triggered a reminder.
- **Ask for notification permission when the person switches the reminder on.** The run's first reminder failed (UNErrorDomain 2003, permission not yet asked); permission was granted a second later and every later reminder was accepted.

**The same-room "No" is the procedure, not the platform.** The guided run restarts the scan when *Start* is tapped, with the app still in front. The camera was in range, so it was found 0.04 s later and the reminder showed as a banner in the app before the phone was locked. iOS didn't report the camera again while it stayed in range, so nothing arrived while locked. Earlier in the same run, iOS had delivered a same-room discovery with the phone locked (11:53:01, RSSI -46, 4.8 s after the app went to the background); the 60 s debounce held that reminder back because one had shown 27 s earlier.

**Still to run:**
- a real arrival: the camera coming into range after being away long enough for iOS to report it afresh, with the phone locked (for example, the camera left in the car and brought in);
- the same-room case with the scan started after the lock, which needs the guided run to wait for the background before restarting the scan;
- the *Creators' App connected*, *Creators' App quit* and *Kill app to test relaunch* rows. No connection event (`ble.proximity.connectionEvent.latency`) arrived in this run.

**Evidence:** Guided run *Bluetooth: what the camera advertises*, 2 Nov 01:38–01:48, build 0.1 (6.1):
- `ble.advert.on.unlinked.seen`, `ble.advert.asleep.unlinked.seen` and `ble.advert.off.unlinked.seen` yes. Each scan logged "services 1800 · company 0x012D".
- `ble.advert.on.connected.seen` yes.
- Proximity filter set to 1800.

Guided run *Bluetooth: proximity reminder*, 2 Nov 11:52–12:01, build 0.1 (6.1), 60 s debounce:
- Next room: *Start* 12:00:47.95, phone locked 12:00:48.92, discovered 12:00:59.71 in the background, locked (`ble.proximity.latency` 11.76 s, RSSI -83); `ble.proximity.detectToNotify` 0.02 s; the reminder was opened 6.8 s later and *Import now* opened the Wired tab; `ble.proximity.reminder.nextRoom` yes.
- Same room: *Start* 11:56:17.17, discovered 11:56:17.22 with the app active (`ble.proximity.latency` 0.04 s); reminder shown in the app (`ble.proximity.detectToNotify` 0.03 s); no discovery while locked or in the background from 11:56:24 to 11:57:56; `ble.proximity.reminder.sameRoom` no.
- Locked same-room discovery: 11:53:01.77, app in the background, RSSI -46, debounced (last reminder 27 s earlier).
- First reminder 11:52:35: not scheduled, UNErrorDomain 2003, `UNAuthorizationStatus=NotDetermined`; permission granted 11:52:36.
- Every discovery was the same peripheral identifier, 683987C3…
- During the Wi-Fi run (12:10:38, app in the background), iOS reported the camera again while its Wi-Fi was being set up, and the reminder was posted. This fits iOS reporting a peripheral afresh when its state changes.

## Open questions from the proposal

| Question | Answer | Evidence |
| --- | --- | --- |
| Which USB connection mode gives `ImageCaptureCore` a session: *Still Img Transfer (MTP)* alone, or also *Select on Connect*? | With the camera asking on connection (*Select USB Connect Mode*), choosing **Image Transfer (MTP)** or **Image Transfer (MSC)** gives a session that lists the card. *Remote Shoot (PC Remote)* enumerates; a session there is untried. *Live Stream* doesn't enumerate. | 1 Nov, Wired tab and log |
| Does the camera emit `ObjectAdded` over USB while in MTP mode, or only in PC Remote mode? | **MTP: not advertised.** DeviceInfo lists three events only: StoreAdded, StoreRemoved and DevicePropChanged; neither ObjectAdded 0x4002 nor Sony's 0xC201. PC Remote mode is still to check (day 4's 60 s watch, in that mode). Over Wi-Fi in PC Remote it does: Sony ObjectAdded 0xC201 [0xFFFFC001] (2 Nov 22:50). | GetDeviceInfo, 1 Nov 19:25, MTP |
| Is the PTP/IP initiator GUID remembered across camera power cycles, or does every connection need re-pairing on the camera? | **No pairing is needed in *PC Remote* on the camera's own network.** A brand-new GUID connected with no prompt. After a power cycle, the same GUID reconnected with no prompt either. Shamil, 2 Nov: nothing to press, apart from switching the camera's Wi-Fi Direct back on. The camera's connection number follows the GUID: #2048075972 in every session with the old GUID, #3502824974 with the new one. Anyone who has joined the camera's Wi-Fi can connect, so its password is the only gate. | Guided run *Wi-Fi: GUID after a power cycle*, 2 Nov 22:29–22:30 |
| Real throughput on the base-model (USB 2) iPhone with a UHS-II card in the camera |  |  |

## α7C II menu wording

The plan's paths use the α7 IV-generation names. Record what the α7C II actually shows.

| Plan's path | Used for | Observed wording |
| --- | --- | --- |
| `Setup → Setup Option → Version` | Firmware check |  |
| `Setup → USB → USB Connection Mode` | Choosing the USB mode | **Can be set to one mode**, so the camera stops asking on every plug (Shamil, guided run 2 Nov 11:28, `usb.mode.fixable` yes). Auto-import on connect is therefore possible once the user has set it. |
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
| (not in the plan) *Still Img. Save Dest.* | Where a picture taken in PC Remote goes | Not under *PC Remote Function*: it is under **Remote Shoot Setting**, set to **Dest. + Camera** (Shamil, 2 Nov). With a full press at 22:50, the frame reached the card and ObjectAdded arrived. The 22:09 test left nothing on the card because it was a half-press. |
| … *PC Remote Cnct Method* = *Wi-Fi Direct* | Day-6 mode |  |
| … *PC Remote Cnct Method* = *Wi-Fi Access Point* | Day-6 mode |  |
| … *Pairing* | PC Remote pairing |  |
| `Network → Transfer/Remote → Select on Camera & Send` | *Send to Smartphone*, the wireless fallback |  |
| *Bluetooth Function* (path not given in the plan) | BLE capture | **On** (Shamil, 2 Nov). |
| *Remote Power ON/OFF* (path not given in the plan) | BLE capture while powered off | **On** during the 2 Nov Bluetooth run (Shamil). Bluetooth stays on whether the camera is on or off, and the camera can still be woken remotely when switched off. |

## Measurements

Paste the output of the Log tab's *Copy measurements table* over this table; it adds "All measurements" and "Device" sections below it.

| Measurement | USB-C (USB 2 iPhone) | Wi-Fi, camera AP | Wi-Fi, UniFi LAN |
| --- | --- | --- | --- |
| Time to enumerate 200 files | 391 files: MTP 64.96 s (ImageCaptureCore), 65.98 s (PTP GetObjectInfo), 152.08 s (MTP GetObjectPropList per object); MSC 7.17 s (12.23 s on the first MSC run) | 391 files in 4.74 s; 419 files in 4.95 s (PC Remote, Sony contents transfer) |  |
| Thumbnail fetch, average per item | MTP 144.8 and 148.1 ms (ImageCaptureCore, two sessions), 143.3 ms (PTP GetThumb); MSC 187.6 ms | 38.74 ms and 35.35 ms (50 newest, slowest about 100 ms) |  |
| ARW throughput, single file | MTP 38.19 MB/s; MSC 39.89 MB/s | 15.50 MB/s (20 ARW, 954 MB, one at a time; 12–17 MB/s per file) |  |
| ARW throughput, two in flight | MTP 39.05 MB/s; MSC 41.73 MB/s | n/a (one transaction per PTP/IP session) | n/a (one transaction per PTP/IP session) |
| MP4 throughput (1 GB clip) | skipped for now (Shamil, 1 Nov) | skipped for now | skipped for now |
| `GetPartialObject` supported | yes: 0x101B (32-bit), 37.29 MB/s in 4 MiB chunks, SHA-256 matches `requestReadData` and `requestDownload` | **yes, through Sony's 0x9211** (SDIO_GetPartialLargeObject: 64-bit offset and length), 12.9 MB/s in 4 MiB chunks; the standard 0x101B (three or four parameters) and 0x9219 answer InvalidObjectHandle in a contents-transfer session |  |
| Resume after link drop verified | yes: GetPartialObject in MTP, cut at 47 % by a cable pull, resumed after a replug, SHA-256 match | **yes:** Wi-Fi switched off at 54 %, reconnected (same handle), resumed with 0x9211, SHA-256 match (2 Nov 23:10) |  |
| `ObjectAdded` event received |  | **yes:** Sony ObjectAdded 0xC201 [0xFFFFC001] within a second of a full shutter press, on a plain *PC Remote* session after the init sequence (22:50). The earlier tests (13:48, 22:09) were half-presses. |  |
| Session survives phone lock (seconds) | **The session survives locks of up to 227 s (the longest tried) and 144 s in another app, but a plain download pauses within 1–2 s and continues on return.** In a continued task the download keeps going while locked. The export's 0.00 s means "no progress while away", not a lost session. | plain download: no progress in 123 s locked, session lost; in a continued task: 20 ARW at 15.4 MB/s, all while locked (57.4 s of progress) |  |
| Camera battery used per 1 GB |  |  |  |
| BLE: advertises when on / asleep / off; service UUID | on yes · asleep yes · off yes (Creators' App quit); UUID 1800 (Generic Access, not Sony-specific) |  |  |

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

All measurements, MTP, build 0.1 (4.1) (1 Nov 2026 23:03, fresh plug, *Wait…* off). The order was *Open session*, *GetThumb, 50 newest (PTP)*, the day-4 steps, then *MTP listing* last. *Thumbnails, 50 newest* recorded no figure (`usb.thumb.avg` is missing):

| Name | Latest value | Unit | Count | Latest context |
| --- | --- | --- | --- | --- |
| `usb.catalog.complete.contended` | 65.11 | s | 1 | open request → complete catalogue, 391 files; 3 PTP pass-through commands from the spike ran during it, not a cold figure |
| `usb.catalog.count` | 391.00 | files | 1 | mediaFiles; contents tree has 0 files; walk 0.6 ms |
| `usb.download.file` | 41.81 | MB/s | 1 | DSC02018.ARW, reference copy for the GetPartialObject comparison [foreground] |
| `usb.getPartialObject.sha256Match` | yes | bool | 1 | DSC02018.ARW: requestReadData MATCH, requestDownload MATCH |
| `usb.getPartialObject.supported` | yes | bool | 1 | DSC02018.ARW fully reassembled with standard32 |
| `usb.getPartialObject.throughput` | 37.29 | MB/s | 1 | DSC02018.ARW, standard32, 4 MiB chunks [foreground] |
| `usb.mtp.proplist` | 60.47 | s | 1 | ObjectFileName only, all objects, depth 0xFFFFFFFF; no answer |
| `usb.mtp.proplist.one` | 0.01 | s | 1 | all properties of the newest object (0x00300123), depth 0 |
| `usb.openSession` | 0.01 | s | 1 | ILCE-7CM2 |
| `usb.ptp.thumb.avg` | 143.30 | ms | 1 | 50 of 50 from the highest handles (no finished listing with object formats this session, so folders may be among them) ok, min 35.6 max 337.6 ms, avg 6 KB [foreground] |
| `usb.readData.throughput` | 41.12 | MB/s | 1 | DSC02018.ARW, 4 MiB chunks [foreground] |

Device: iPhone18,4; iOS 27.2 (24B119); spike 0.1 (4.1); Low Power Mode off; thermal nominal.

New measurements, MTP, build 0.1 (5.1) (1 Nov 2026 23:34–23:42).
- **Order:** fresh plug, *Wait…* off, *Open session*, *MTP listing* straight away, then *Thumbnails, 50 newest*, *PTP listing* and *MTP listing* again.
- **Not included:** the measurements carried over from 23:03.
- **False reading:** the export's `usb.lifecycle.progressAfterBackground` 0.00 s, which the table puts under "Session survives phone lock", is not a real figure. The phone was locked 1 s after the PTP listing finished, and the lifecycle monitor still counted that as a transfer running.

| Name | Latest value | Unit | Count | Latest context |
| --- | --- | --- | --- | --- |
| `usb.catalog.complete.contended` | 65.05 | s | 2 | open request → complete catalogue, 391 files; 3 PTP pass-through commands from the spike ran during it, not a cold figure |
| `usb.mtp.listing` (first run) | 212.70 | s | 1 | 391 files, 6 folders, one GetObjectPropList per object, newest first; GetObjectHandles 60.24 s; ImageCaptureCore catalogue running (0 % at the start), complete at the end |
| `usb.mtp.proplist.perObject` (first run) | 383.88 | ms | 1 | untouched, after ImageCaptureCore's catalogue: 395 at 385.1 ms average (min 10.0, max 800.5); untouched, while it ran: 2 at 137.1 ms average (min 48.2, max 226.1) |
| `usb.mtp.listing.newest50` (first run) | 76.18 | s | 1 | GetObjectHandles plus the 50 highest handles; catalogue running at the start, complete by the 50th |
| `usb.thumb.avg` | 148.08 | ms | 1 | 50 of 50 newest ok, min 67.2 max 301.6 ms, avg 6 KB, run 1 this session [foreground] |
| `usb.ptp.catalog` | 65.98 | s | 1 | 397 objects, 391 files, 6 folders; GetObjectHandles 0.04 s; ImageCaptureCore usb.catalog.complete.contended 65.0 s |
| `usb.mtp.listing` (second run) | 152.08 | s | 2 | 391 files, 6 folders; GetObjectHandles 0.00 s; PTP listing 65.98 s this session; catalogue complete |
| `usb.mtp.proplist.perObject` (second run) | 382.93 | ms | 2 | touched earlier this session: 397 at 382.9 ms average (min 6.9, max 801.4) |
| `usb.mtp.listing.newest50` (second run) | 15.75 | s | 2 | GetObjectHandles plus the 50 highest handles; catalogue complete |

Device: iPhone18,4; iOS 27.2 (24B119); spike 0.1 (5.1); Low Power Mode off; thermal nominal.

## Day-6 mode matrix

One row per camera mode. Note in the last column when the Mac (`gphoto2`, `nmap`, `tcpdump`) and the iPhone (Wi-Fi tab) disagree, and whether the card listing shows on-card objects or only tethered captures.

| Camera mode | SSDP | Port 15740 open | Handshake accepted | Card listed | Notes |
| --- | --- | --- | --- | --- | --- |
| Smartphone Connect | dropped 3 Nov: covered by the Bluetooth switch-on, the smartphone connection Creators' App uses (the camera showed no QR code on 2 Nov) |  |  |  |  |
| PC Remote over Wi-Fi Direct (camera's own network; method to confirm) | **announces:** NOTIFY to the multicast group, received in 0.73 s without the entitlement; no answer to a unicast M-SEARCH; our multicast M-SEARCH never sent | **yes**, 1.53 s, including allowing the Local Network prompt | **yes**, 0.02 s; Init_Command_Ack after 6 ms, so probably no prompt on the camera | **yes, through Sony's contents transfer:** 391 files in 4.74 s after SDIO_OpenSession [1,1] and 0x9212 [2,0,0] → [2,1,0]; a plain session gets StoreNotAvailable (0x2013) even after the init sequence | iPhone only, no Mac probes. Bonjour `_ptp._tcp`: none. Joined in Settings (no QR code in PC Remote). Build 8 run (12:08) labelled *Smartphone Connect*; build 9 run 13:47 |
| PC Remote over Access Point |  |  |  |  |  |

## PTP/IP and join facts

| Question | Finding | Evidence |
| --- | --- | --- |
| What the camera shows on the first connection from the iPhone | Not recorded. In *PC Remote* the Init_Command_Ack came 6 ms after the request, so the camera probably didn't ask. To confirm with Shamil. | Wi-Fi run, 2 Nov 12:14:04 |
| GUID persistence after a power cycle (no prompt / prompt once / prompt every time) | **No prompt.** The same GUID reconnects after a power cycle with nothing to press (Init_Command_Ack 6 ms). The run recorded "Yes, it asked", but Shamil confirmed (2 Nov) that the only step was switching the camera's Wi-Fi Direct back on. After the restart, the camera's Wi-Fi had to be switched on again on the camera, and the phone had moved to the home Wi-Fi, so it was rejoined in Settings. | 2 Nov 22:29:57 |
| What the camera shows for a new GUID | Nothing: "No, it connected" (Init_Command_Ack 5 ms, Init_Event_Ack 74 ms). | 2 Nov 22:30:07 |
| Operations listed in DeviceInfo over PTP/IP, compared with USB | **PC Remote, camera's own network:** vendor extension Sony v100 "Sony PTP Extensions" (USB MTP: none), functional mode 0. **81 operations** (USB MTP: 24): the PTP basics with GetPartialObject 0x101B and GetThumb, 0x100D, Sony 0x9201–0x9254, and MTP 0x9801–0x9803 and 0x9805 GetObjectPropList. The Sony operations include SDIO_Connect 0x9201, SDIO_GetExtDeviceInfo 0x9202, SDIO_GetPartialLargeObject 0x9211 and SDIO_SetContentsTransferMode 0x9212. No GetPartialObject64 (0x95C1). **48 events**, including StoreAdded, StoreRemoved, **Sony ObjectAdded 0xC201** and ObjectRemoved 0xC202 (USB MTP: 3). **0 device properties** (USB MTP: 5). Image formats: Association, EXIF/JPEG, Sony ARW, 0x300B, MP4, Sony HEIF. Firmware string **2.01**; Setup records 2.0 from USB on 1 Nov. Fixtures on the phone: `ptpip/deviceinfo.bin` (475 B, serial zeroed), `ptpip/FIRMWARE`. | Wi-Fi run, 2 Nov 12:14:04 |
| Sony SDIO connect: response codes and whether the operation list changes | **All OK, and nothing changes.** Imagedge's order: GetDeviceInfo; GetStorageIDs (StoreNotAvailable); SDIO_Connect 1 and 2 (OK, 8 zero bytes each); SDIO_GetExtDeviceInfo 0x12C (OK, 970 bytes: version 0x12C, 421 codes then 59); SDIO_Connect 3 (OK); GetExtDeviceInfo again (the same 970 bytes). DeviceInfo before and after: 81 operations, 48 events, 0 properties, functional mode 0. With the sequence, the plain session stayed up past 30 s (13:48:18 to 13:48:57, then closed on purpose). Without it, on build 8, the connection was gone within 37 s. | Wi-Fi run, 2 Nov 13:48:18 (build 0.1 (7.1)) |
| Camera's IP address on its own access point | **192.168.122.1** (the PTP/IP port and the SSDP announcements both came from it) | Wi-Fi run, 2 Nov 12:13 |
| Phone's internet while joined to the camera's access point (`NWPath`) | **Kept, over mobile data.** Joined to the camera, the path showed Wi-Fi present but not used, cellular in use, and the carrier's gateway. Traffic to 192.168.122.1 still went over Wi-Fi. Before the join, the path was home Wi-Fi with gateway 192.168.1.1. | Wi-Fi run, 2 Nov 12:08:57 and 12:13:28 |
| QR code format and the fields it holds (names only, never values) |  |  |
| Join flow: system sheets and prompts seen, and `ptpip.ap.join` | `ptpip.ap.join` not measured yet: in *PC Remote* the camera shows no QR code, so the phone joined in Settings › Wi-Fi. From build 9 the guided run then finds the camera by itself (192.168.122.1:15740 answered in 0.01 s). On build 8 the step stopped at "no SSID to join". | Wi-Fi runs, 2 Nov 12:13:33 and 13:47:50 |
| When the Local Network prompt appeared | **At the first connection to the camera** (the TCP 15740 probe). Until it was allowed, the connection waited with "Network is down" (POSIX 50); the probe succeeded 1.53 s after it started. | Wi-Fi run, 2 Nov 12:13:41 |
| An idle session with the app in the background (not in the plan) | **Lost.** The app went to the background 6 s after the run's last command and came back 26 s later. Both channels then failed with "Software caused connection abort" (POSIX 53). Seven seconds later the phone left the camera's network for the home Wi-Fi. Two causes are possible and the run can't tell them apart: iOS closing a suspended app's sockets, or the camera dropping an idle session (the ZV-E10 code above reports about 30 s and sends GetDeviceInfo every 10 s to prevent it). Either way, 1.0 needs a keep-alive and an automatic reconnect on return to the front. | Wi-Fi log, 2 Nov 12:14:05–12:14:49 |

## BLE advertisement

With Bluetooth Function on and Remote Power ON/OFF on. Interval is the median gap between scan callbacks, so an upper bound.

| Camera power | Advertises | Service UUIDs | Manufacturer data | Interval | Seen from the next room |
| --- | --- | --- | --- | --- | --- |
| On | yes: 23 in 30 s with Creators' App quit, 1,083 with it connected | 1800 | company 0x012D, 20 bytes after it. Bytes 6–8 and 12–13 (counting from 0 after the company ID) change while Creators' App is connected. | about 1,024 ms with the app quit; about 43 ms with it connected | not run |
| Asleep | yes: 26 in 30 s | 1800 | the same as *On* with the app quit | about 2,037 ms | not run |
| Off | yes: 34 in 30 s | 1800 | the same as *On* with the app quit | about 1,529 ms | not run |

Settings as they were on the camera (Bluetooth Function on). Whether *Remote Power ON/OFF* was on is not recorded. RSSI was about -83 dBm with the app quit and -62 dBm in the connected run; the phone's distance is not recorded. Guided run, 2 Nov 01:38–01:44.

By pairing context (the setup with Creators' App paired on the same iPhone):

| Pairing context | Advertises (on / asleep / off) | Connected to the system (`ble.connected.<state>.<pairing>.seen`) | Connection event received | Notes |
| --- | --- | --- | --- | --- |
| Creators' App connected | on: yes (fast, about every 43 ms); asleep and off not run | yes (`ble.connected.on.connected.seen`): the system lists the camera as connected (another app holds it) | — | still advertises while connected |
| Creators' App quit, link down | yes / yes / yes | no / no / no | — | the state our users will usually be in |
| Not paired | skipped (needs pairing again) | | | |

Proximity filter UUID chosen: **1800** (Generic Access), the only service UUID the camera advertises, the same with Creators' App quit and connected. It isn't Sony-specific, so the app confirms the camera after a wake by its peripheral identifier or Sony's company ID.

GATT services (Bluetooth tab › *List services*, 2 Nov 22:59, build 0.1 (9.1); a short connection with no reads or writes): **8000FF00**, **8000CC00**, **8000DD00**, **8000EE00** and **8000BB00**, each `-xx00-FFFF-FFFF-FFFFFFFFFFFF`.
- Reverse-engineered notes on Sony's apps (unverified on the α7C II) call 8000CC00 *Camera Control*. They say it carries the **Wi-Fi handover**: write 0x01 to CC08 to start the camera's Wi-Fi, then read the network name (CC06) and password (CC07).
- 8000FF00 is the remote-shutter service, 8000DD00 location and time, and 8000EE00 Sony's own pairing. 8000BB00 isn't in any source found.
- The advertisement's tag 0x21 read **0xF0**. In the same notes' layout that means the camera is on, and Wi-Fi handover is supported and enabled. Whether the layout holds on this body is unverified.
- The rest of the manufacturer data isn't recorded here, because it may identify the camera.
- Build 10 tests the handover.

**Wi-Fi handover over Bluetooth, first run** (guided run *Bluetooth: Wi-Fi handover*, 3 Nov 00:04–00:09, build 0.1 (11.1)). Setup: camera on after a restart with its Wi-Fi off; PC Remote Function on; Creators' App quit; Bluetooth Rmt Ctrl on.
- **Connecting needs no pairing prompt.** A 10 s scan found the camera; it connected in 0.45 s and listed all five services in 1.05 s. 8000CC00 has about 80 characteristics, including CC06, CC07, CC08, CC09, CC0A, CC0B and CC0C as the notes describe. No ATT error appeared, and iOS showed no pairing request. (Creators' App's bond with the camera was already on the phone.)
- **The camera hands over its Wi-Fi details to our app.**
  - CC0A read "2.01" (firmware) and CC0B "ILCE-7CM2" (model).
  - CC06 is 24 bytes: a 3-byte header, then a 21-character network name beginning DIRECT-.
  - CC07 is 11 bytes: the 3-byte header, then an 8-character printable password.
  - CC0C (BSSID) is present and MAC-shaped.
  - Values are not recorded. Whether they are the network PC Remote uses is still to compare.
- **Switching the Wi-Fi on didn't work in this setup.**
  - Writing 0x01 to CC08 was acknowledged in 58 ms.
  - CC09 changed in one byte at +0.15 s and changed back at +2.34 s. CC09's layout doesn't match any of the guessed tag layouts.
  - Nothing changed on the camera, and no network appeared.
  - The likeliest cause is that **PC Remote Function was on**: the handover belongs to the smartphone connection, and Smartphone Connect showed no QR code in the same state on 2 Nov. That is to test with PC Remote Function off.
- **The join failed because there was no network.** iOS asked to join (`ble.handover.joinPrompt` yes) and apply returned after 7.5 s, but no Wi-Fi path appeared and 192.168.122.1:15740 didn't answer within 60 s.
- **Creators' App said "not connected" afterwards** (`ble.handover.creatorsAppStillWorks` no). The run wrote nothing to the pairing service (EE01), only CC08. PC Remote Function being on may also explain this. To check with it off before blaming the run.
**Second run** (3 Nov 00:20–00:22, build 0.1 (11.1)): the same Wi-Fi-on step, and the camera's PC Remote Function off as far as the setup goes (to confirm).
- **Creators' App connected afterwards** (`ble.handover.creatorsAppStillWorks` yes). The first run's "not connected" was PC Remote Function being on, not damage from the run.
- **Bluetooth reconnected** by the identifier saved in the first run, in 0.38 s.
- **The camera starts its Wi-Fi when asked, then gives up.**
  - CC08 = 0x01 was acknowledged again in 58 ms.
  - The same one byte of CC09 went 0 → 1 → 0 in both runs, at +0.15 s and +2.4 s. The notes' CC09 layout gives the Wi-Fi status values as 0 Terminated, 1 Launching, 2 Launched and 3 Terminating, so this reads as *launching*, then *terminated*. (The spike's CC09 parser guessed the tag layout wrong, so it didn't label the byte.)
  - Something else has to be in place before the camera brings its Wi-Fi up for a phone. The third run (below) found it: the app must be subscribed to the camera's status notifications.
- **The network details depend on the camera's setup.** With PC Remote off, reading CC06 failed with the camera's own ATT error **0x9D**. With PC Remote on (first run) it gave the name and password. So the camera hands over whichever Wi-Fi network is configured, and nothing when none is.
- **Reading the details again** (Bluetooth tab, 3 Nov before 00:42, build 0.1 (11.1)), with PC Remote's Wi-Fi Direct network up: two reads, each a 21-character name in the `DIRECT-xxXX:ILCE-7CM2` shape and an 8-character password. The tab only read them, so the join was done in Settings; the camera then answered at 192.168.122.1:15740 at once.

**Joining with the details read over Bluetooth, end to end** (guided run *Bluetooth: join with the camera's Wi-Fi on*, 3 Nov 11:33–11:34, build 0.1 (12.1)). Setup: PC Remote on with its Wi-Fi Direct network up, the camera's network forgotten in Settings first, Creators' App quit. Times are from the Start tap, less the 9.6 s spent answering the app's own question.

| Step | From Start |
| --- | --- |
| Bluetooth connect (0.50 s, by the saved identifier), service discovery and the network details read (`ble.join.toDetails`) | 2.45 s |
| iOS join prompt accepted; `apply` returned after 7.7 s, Wi-Fi path with gateway 192.168.122.1 after 10.6 s (`ptpip.ap.join`) | |
| The camera answers at 192.168.122.1:15740 (`ble.join.toCameraPort`) | 13.76 s |
| Whole-card contents transfer ready (2.01 s), 425 objects listed (4.97 s), the newest ARW (46.3 MB) downloaded at 12.8 MB/s (`ble.join.toFirstFile`) | 25.06 s |

- One iOS prompt to join (`ble.join.joinPrompt` yes); no Bluetooth pairing request (`ble.join.pairingPrompt` no).
- The details read over Bluetooth are the network the camera's PTP/IP server is on: the import worked without any typing, QR code or Settings.

**Third run: the camera switches its Wi-Fi on over Bluetooth** (guided run *Bluetooth: Wi-Fi handover*, 3 Nov 11:35–11:42, build 0.1 (12.1)). Setup: camera on with its Wi-Fi off (PC Remote Function off), Bluetooth Rmt Ctrl on, photos on the card, Creators' App quit.
- **The missing precondition is the status notifications.** The app first subscribed to notifications on CC09, CC10, CC0F, CC03 and CC0E (the set Sony's app is reported to use; all five confirmed). Then CC08 = 0x01 (acknowledged in 62 ms) took CC09's Wi-Fi status **0 → 1 at +0.09 s → 2 at +2.22 s** (*launching*, then *launched*), and it **stayed at 2**. In the earlier runs, without subscriptions, the same write went 0 → 1 → 0.
- **The camera's screen shows nothing.** The tester saw no change on the camera although CC09 said *launched*. The run went by the screen, so it never tried to read the details and join; build 13 goes by CC09.
- **Creators' App used the Wi-Fi the spike had switched on.** With the spike still connected and subscribed, Creators' App imported successfully. CC09 stayed at 2 throughout, so the Wi-Fi never went off and came back. One CC09 notification at 11:36:34, with the status unchanged, looks like the one the spike's own second CC08 write caused at 11:35:53, so Creators' App probably wrote CC08 too (Sony's app is reported to skip it when the Wi-Fi is already launched). The Wi-Fi had then been up about 5 minutes, at least 52 s of it before Creators' App can have joined; see *How long an unused Wi-Fi stays up* below.
- **The camera switches its Wi-Fi off when the importing app leaves.** About 1 s after Creators' App went to the background, CC09 went 2 → 3 (*terminating*), then 3 → 0 4.5 s later. 15 s after Creators' App was quit the status was still 0, and the tester confirmed the Wi-Fi was off.
- **Notifications seen while Creators' App connected:** one CC09 entry (status still 2) and CCA1 `04 00 00 02 01` (an entry with tag 0x0000; meaning unknown).
- All 13 subscriptions were turned off at the end and the camera confirmed each one. Creators' App still connected afterwards (`ble.handover.creatorsAppStillWorks` yes). No pairing request.
- **CC09's layout on the α7C II:** a list of entries, each *length* (1 byte, counting tag and value), *tag* (2 bytes, big-endian), *value*. A read returns all ten tags (43 bytes):

  | Tag | Meaning (from the notes) | Value with the Wi-Fi off |
  | --- | --- | --- |
  | 0x0001 | Wi-Fi status: first value byte 0 terminated, 1 launching, 2 launched, 3 terminating (all four seen) | `00 00` |
  | 0x0002 | Image transfer available | 1 |
  | 0x0003 | Remote control available | 1 |
  | 0x0004 | unknown | `00 00 00` |
  | 0x0005 | Time set | 1 |
  | 0x0006 | unknown | 0 |
  | 0x0007 | Live streaming | 0 |
  | 0x0008 | Movie recording | 0 |
  | 0x0009 | Streaming mode | 0 |
  | 0x000A | Background transfer available | 1 |

  A notification carries one entry, for example `04 00 01 02 00` (Wi-Fi status 2). The spike's parser had assumed tag before length.
- **The 8000CC00 service has 80 characteristics, 13 of them notifiable:** CC03, CC09, CC0E, CC0F, CC10, CC19, CC20, CC21, CC61, CC71, CCA1, CCA5 and CCA9.

**What this means for 1.0:**
1. The app connects over Bluetooth, subscribes to the camera's status notifications and writes CC08 = 0x01. The camera's Wi-Fi is up about 2.2 s later, with nothing to do on the camera.
2. The app reads the network name and password over Bluetooth and joins with one iOS prompt the first time.
3. The camera switches its Wi-Fi off again by itself, which suits the camera's battery: about 1 s after Creators' App goes to the background, and otherwise about 50 s after the iPhone leaves its network (seen once) or after a single switch-on nobody joins (seen twice; once, at 11:54, about 30 s) (below).

**The 1.0 route, end to end: Bluetooth switches the Wi-Fi on, the app joins and imports** (guided run *Bluetooth: switch Wi-Fi on, join and import*, 3 Nov 14:56–15:04, build 0.1 (13.1)). Setup: camera on with its Wi-Fi off (PC Remote Function off), Creators' App quit, the camera's network forgotten in Settings first. Nothing was done on the camera. Times are from the Start tap.

| Step | Took | From Start |
| --- | --- | --- |
| Bluetooth connect by the saved identifier (0.4–0.5 s in earlier runs) | 5.56 s | |
| Service discovery, Sony's five notifications on, CC09 read | 3.9 s | |
| CC08 = 0x01 (acknowledged in 55 ms) → Wi-Fi status 1 at +0.09 s → 2 at +0.84 s (`ble.auto.toWiFiOn`) | 0.84 s | 10.36 s |
| Network details read on the first try, 0.45 s after status 2 (`ble.auto.toDetails`) | 0.45 s | 10.82 s |
| iOS join prompt accepted; `apply` returned after 7.4 s; the camera answered at 192.168.122.1:15740 0.1 s later (`ble.auto.toCameraPort`) | 8.0 s | 18.78 s |
| Whole-card contents transfer ready (1.97 s), 425 objects listed (6.07 s), newest ARW (46.3 MB) at 9.1 MB/s (`ble.auto.toFirstFile`, less 2.8 s on the app's own question) | 13.6 s | 32.38 s |

- **The network details can be read once Bluetooth has switched the Wi-Fi on**, with PC Remote off: CC06/CC07 gave the same 21-character `DIRECT-` name and 8-character password on the first try. With the Wi-Fi off they fail with 0x9D, so the app reads them after status 2.
- **The camera's screen showed nothing** throughout (`ble.auto.cameraShowsWiFi` no).
- **The Wi-Fi survives the Bluetooth link closing.** With the notifications turned off and Bluetooth disconnected, a 46.3 MB ARW downloaded 14 s later and again 64 s later, both at about 13 MB/s.
- **The camera doesn't switch its Wi-Fi off when the session ends** (`ble.auto.wifiOffAfterSession` no). After CloseSession, with the phone still joined to the camera's network, CC09 read status 2 every 2 s for 45 s. Creators' App's Wi-Fi went off about 1 s after it left, so Creators' App probably tells the camera (leaving alone took about 50 s; below); how it does so is still to find.
- No Bluetooth pairing request; Creators' App connected afterwards.

**The same run with Creators' App open in the background, then leaving the network** (guided run *Bluetooth: switch Wi-Fi on, join and import*, 3 Nov 22:43–22:48, build 0.1 (14.1)). Setup: camera on with its Wi-Fi off (PC Remote Function off), Creators' App open in the background, the camera's network not forgotten in Settings. Nothing was done on the camera. Times are from the Start tap.

| Step | Took | From Start |
| --- | --- | --- |
| Bluetooth connect: iOS already held a link to the camera (Creators' App's), so it was immediate | 0.00 s | |
| Service discovery (0.02 s), Sony's five notifications on (1.4 s), CC09 and CCAB read | 3.4 s | |
| CC08 = 0x01 (acknowledged in 56 ms) → Wi-Fi status 1 at +0.09 s → 2 at +2.34 s (`ble.auto.toWiFiOn`) | 2.5 s | 5.94 s |
| A CCAB read, then the network details read on the first try, 0.47 s after status 2 (`ble.auto.toDetails`) | 0.94 s | 6.88 s |
| iOS join prompt accepted; `apply` returned after 8.0 s; the camera answered at 192.168.122.1:15740 0.1 s later (`ble.auto.toCameraPort`) | 8.7 s | 15.61 s |
| Whole-card contents transfer ready (2.03 s), 547 objects listed (7.32 s), newest ARW (39.0 MB) at 10.0 MB/s (`ble.auto.toFirstFile`, less 2.5 s on the app's own question) | 13.9 s | 29.52 s |

- **The route works with Creators' App open, and nothing dropped this time.** The camera kept its card, its Wi-Fi and the Bluetooth link for the whole run (about 4 minutes: a listing, three downloads and the lifecycle steps). Earlier runs with Creators' App open lost the Wi-Fi and the link 30 s after a switch-on nobody joined (11:54) and the card 28 s into a copy (15:14), so the drop happens sometimes, not every time.
- **Bluetooth is quicker when Creators' App holds the link.** Our connect was immediate (0.00 s, against 5.2–5.6 s for the first connect to an idle camera). The switch-on took 2.34 s, but it took 2.2–2.5 s with Creators' App quit too (11:35, 22:56), against 0.8 s in the 13.1 runs, so Creators' App doesn't explain the slower switch-on (Creators' App's own, 2.1–2.5 s).
- **The Wi-Fi outlived our Bluetooth link again** (`ble.auto.wifiSurvivesBluetoothOff` yes 13 s after, 13.8 MB/s; `.60s` yes 63 s after, 14.0 MB/s). Weaker than the 13.1 runs: iOS still listed a camera link afterwards (Creators' App's), so the camera's Bluetooth never went down.
- **Turning the notifications off isn't confirmed while another app shares the link.** Only CC0E came back confirmed; CC03, CC09, CC0F and CC10 returned CoreBluetooth's "unknown" error. iOS shares one link, and one set of notification switches, between the apps using a device, so it probably keeps on a notification Creators' App still wants and reports our request as an error. Creators' App connected and worked afterwards (`ble.auto.creatorsAppStillWorks` yes). 1.0 can treat this error as harmless when iOS lists another app's link to the camera.
- **The camera keeps its Wi-Fi up while the phone stays joined** (`ble.auto.wifiOffAfterSession` no): status 2 for 45 s after CloseSession, as in the 13.1 runs.
- **Leaving the network makes the camera switch its Wi-Fi off, after about 51 s.** The app removed its hotspot configuration 46 s after CloseSession, and the iPhone left the camera's network 0.1 s later (its Wi-Fi path went to none, then to the home network). CC09, read every 2 s over the Bluetooth link, stayed at 2, then went 2 → 3 (*terminating*) 51.2 s after the removal and 3 → 0 at 53.2 s (`ble.auto.wifiOffAfterLeaving` yes, `ble.auto.wifiOffAfterLeaving.latency` 53.2 s).
  - *Bluetooth: how long an unused Wi-Fi stays up* (below) points to the leave as the cause: with nobody joined, the camera starts switching its Wi-Fi off about 50 s after a switch-on, the same delay as here after the leave. A timer of 95–97 s from the session's end would also fit this one run, but would have to land 50 s after the leave by coincidence.
  - Creators' App's Wi-Fi went off about 1 s after it left (11:35), much sooner, so Creators' App probably tells the camera, over PTP/IP or Bluetooth, rather than only leaving.
  - If 1.0 leaves the camera's network after an import, the camera's Wi-Fi is off within about a minute, which is enough for its battery. A faster switch-off would need a write the spike hasn't made; 1.0 doesn't need one.
- **CCAB read `04 00 00 02 03` with the camera's menu on 5 GHz** (`ble.handover.wifiBand` 2): one entry, tag 0x0000, value 02 03, the same with the Wi-Fi off, right after status 2 and after the import. One menu setting gives one point, so the notes' mapping is still unverified; 1.0 doesn't need it.
- No Bluetooth pairing request (`ble.auto.pairingPrompt` no); the camera's screen showed nothing (`ble.auto.cameraShowsWiFi` no).

**How long an unused Wi-Fi stays up** (guided run *Bluetooth: how long an unused Wi-Fi stays up*, 3 Nov 22:55–22:59, build 0.1 (14.1), run twice). Setup: camera on with its Wi-Fi off (PC Remote Function off). The app switched the Wi-Fi on over Bluetooth with a single CC08 = 0x01 (Sony's five notifications on), stayed connected with the notifications on, and nobody was meant to join the camera's network: the iPhone wasn't on it at the start or the end of the watch, the app stayed in front, and no other device was used. Times are from status 2, by the notifications.

| Run | Creators' App | Bluetooth connect | CC08 to status 2 | Status 2 → 3 (*terminating*) | Status 0 |
| --- | --- | --- | --- | --- | --- |
| 22:56 | quit; no system link to the camera; the camera's network forgotten in Settings | 0.57 s | 2.46 s | 49.8 s | **51.2 s** |
| 22:58 | open in the background; one system link; the network not forgotten | 0.03 s | 2.31 s | 49.9 s | **51.5 s** |

`ble.idle.wifiUpWithBluetooth` gives 51.31 s and 51.63 s: the app's wait saw status 0 about 0.1 s after the notification.

- **With nobody joined after a single switch-on, the camera switched its Wi-Fi off by itself about 50 s later**, once with Creators' App quit and once with it open: 49.8–49.9 s after status 2, or 52.3–52.5 s after the CC08 write (these runs can't tell which starts the count). A Bluetooth link with Sony's notifications on doesn't keep it up, and the link stayed up after the Wi-Fi went off (`ble.idle.linkDropped` no). The run's second phase (Bluetooth off for 60 s, then a status read) didn't run, because the Wi-Fi was already off.
- **A second CC08 write may restart the count.** In the 12.1 handover run (11:35) the Wi-Fi was still at status 2 51.9 s after it came up, which a plain 50 s count doesn't allow. That run had written CC08 = 0x01 a second time 11.2 s after status 2. Creators' App, opened 38 s after status 2, probably wrote it again at 51.9 s (the CC09 notification above), so it may not have joined before then. Not tested directly.
- **The 11:54 loss was something else.** There, with Creators' App open, the Wi-Fi and the Bluetooth link went about 30 s after a switch-on nobody joined. It came earlier and took the link with it, so it looks like the drop seen with Creators' App open rather than this switch-off. When that drop happens, the time to join is shorter.
- **The leave in the 22:43 run fits the same count.** There the camera began *terminating* between 49.1 s and 51.1 s after the iPhone left (CC09 read every 2 s), the delay seen here. A 50 s count from CloseSession or from the last PTP/IP traffic is ruled out: CC09 was still 2 95 s after CloseSession, and the phone had stayed on the network for the first 46 s of that. So the simplest rule that fits: about 50 s after the camera last had a phone on its network, or after a switch-on nobody joins, it starts switching its Wi-Fi off, unless the leaving app tells it to go sooner, as Creators' App appears to. Seen once after a leave and twice unjoined, each time with a Bluetooth link up.
- **What this means for 1.0:**
  - When the import ends, leave the camera's network. In the one run so far the camera's Wi-Fi started switching off about 50 s later and was off by 53 s, with no write (a Bluetooth link was up). The only leave tried removes the app's hotspot configuration, which may bring the iOS join prompt back at the next import; check that before 1.0 relies on it.
  - The phone has up to about 50 s from status 2 to join. The joins so far took 7.4–10.6 s including the prompt, so there is room. The app should still watch CC09 during the join prompt: if CC09 reaches 3 or 0 before the join, it writes CC08 = 0x01 again (reconnecting Bluetooth first if the link went too) and retries the join.
  - Any leave starts the count, including iOS moving the iPhone to another network while the app is in the background (2 Nov 12:14; *PTP/IP and join facts* above). An import resumed more than about 50 s after that needs Bluetooth to switch the Wi-Fi on again before the rejoin and reconnect; build 14's copy recovery does this.
  - Switching the Wi-Fi on early (when the camera is found, before the person decides) costs the camera about 50 s of Wi-Fi per switch-on if nobody joins (seen with the Bluetooth link up; with the link dropped it's untested). It only saves time if the person starts within about 40 s; after that the app switches it on again.
- **Turning the notifications off: all five confirmed with Creators' App quit, only CC0E with it open** (the other four "CoreBluetooth unknown", as in the 22:43 run). That fits the shared-link explanation above. Creators' App connected afterwards both times (`ble.idle.creatorsAppStillWorks` yes).
- **CC10 notified twice, at the same moment, with Creators' App quit**, 24 s into the watch: the same 19 bytes both times, `·· 00 00 02 03 00 01 00 04 00 00 00 00 ·· 00 00 00 00 01` (bytes above 0x0F masked). Meaning unknown; nothing followed.
- CCAB read `04 00 00 02 03` again, with the Wi-Fi off and on, in both runs.

Still open:
- whether a second CC08 = 0x01 while the status is 2 restarts the 50 s count (the 11:35 run hints it does), and what a write during status 3 does;
- whether a phone that stays joined without a session keeps the Wi-Fi up past about 100 s after CloseSession (the direct test against a timer from the session's end);
- an unused Wi-Fi with Bluetooth off (the run's second phase didn't run);
- why the 11:54 run lost the Wi-Fi and the link after about 30 s, and what Creators' App does to get a 1 s switch-off;
- why the Bluetooth connect took 5.6 s this time (0.4 s in earlier runs, and one 8 s timeout at 11:53 before a scan found the camera). A second run at 15:21 took 5.2 s for the first connect and 0.37 s for a reconnect a minute later, so the camera seems slow to take the first connection after it has been idle. The 15:21 run otherwise matched the first: Wi-Fi status 2 at +0.81 s, `ble.auto.toWiFiOn` 9.88 s, `ble.auto.toFirstFile` 36.8 s, and the Wi-Fi again outlived Bluetooth (14 s and 64 s) and stayed up for 45 s after the session closed. At 22:56 the first connect took 0.57 s, 8 minutes after this app's last link closed; Creators' App had held its own link until it was quit just before that run, so the camera may not have been idle.

- **Background discovery worked with Low Power Mode on.** The proximity scan found the camera in the background at 00:08 although the device reported Low Power Mode on, contrary to the app's warning text.

Proximity test:

| Scenario | Detected after (`ble.proximity.latency`) | Reminder posted after (`ble.proximity.detectToNotify`) | Connection event after (`ble.proximity.connectionEvent.latency`) | Notes |
| --- | --- | --- | --- | --- |
| Phone locked, same room | 0.04 s, but with the app still in front (the scan restarted on *Start*, before the lock) | 0.03 s, shown as a banner in the app | none | `ble.proximity.reminder.sameRoom` no: no discovery while locked, because iOS doesn't report a camera again while it stays in range. A procedure artefact; see the finding |
| Phone locked, next room | **11.76 s**, in the background, locked, RSSI -83 | **0.02 s** | none | `ble.proximity.reminder.nextRoom` yes; reminder opened 6.8 s later, *Import now* opened the Wired tab |
| Creators' App connected | not run |  |  |  |
| Creators' App quit | not run |  |  |  |
| After *Kill app to test relaunch* | not run |  |  |  |

## ImageCaptureCore facts

| Question | Finding | Evidence |
| --- | --- | --- |
| USB connection mode(s) that enumerate in `ICDeviceBrowser`, and the ones Photos imports from | **Three of the four enumerate.** *Image Transfer (MTP)* and *Remote Shoot (PC Remote)*: `ILCE-7CM2`, `ICTransportTypeUSB`, 1 capability. In MTP: `kind=Camera`, `type=0x101`, USB `054C:0E8B` (Sony), the one capability is `ICCameraDeviceCanAcceptPTPCommands` (`acceptsPTPCommands=yes` before and after opening), the session opens in 0.04 s, but **the catalogue stayed at 0 %, 0 files, for at least 35 s** (1 Nov 19:03:09–19:03:46), then listed **391 files: 231 ARW (9,846.9 MB) and 160 JPG (3,433.4 MB)**. **Clean run, app in front: `usb.openSession` 0.03 s, `usb.catalog.complete` 64.82 s** (0 % throughout, then all 391 at once, with `ICCameraDeviceSupportsHEIF` added as it completed). In MTP `mediaFiles` has 391 files but the `contents` tree has none (in MSC both have 391). (First run 19:03–19:05; clean run 19:18:29–19:19:34.) Thumbnails, 50 newest: **144.8 ms average** (min 29.3, max 301.2), 50 of 50, about 6 KB JFIF each, run 1. Both miss day 2's targets (200 files listed in ≤ 2 s, thumbnails ≤ 50 ms). The device UUID embeds a 12-character hex string that looks like the camera's USB serial. *Image Transfer (MSC)*: `Untitled` (the card's volume), `ICTransportTypeMassStorage`, 2 capabilities; the card also mounts in the Files app as *Untitled* › `DCIM/100MSDCF` (391 items on 1 Nov, two files per frame with the same name, about 44–48 MB and 22–26 MB). In MSC: `kind=Camera`, `type=0x101`, USB `0000:0000`; capabilities `ICCameraDeviceCanDeleteOneFile` and `ICCameraDeviceCanAcceptPTPCommands` (`acceptsPTPCommands=yes`), plus `ICCameraDeviceSupportsHEIF` 5 s after opening. The session opens in 0.00 s; **`usb.catalog.complete` 12.23 s for 391 files** (0 % for about 4 s, then 40 → 387 files in 6 s); the `mediaFiles` and `contents` counts agree; handles are 0, as expected for mass storage. **Thumbnails, 50 newest: 187.56 ms average** (min 14.9, max 646.2), about 7 KB. **The PTP flag is misleading in MSC:** GetDeviceInfo and GetStorageIDs got no reply in 60 s, and GetObjectHandles none in 120 s. The product must decide by transport type, not by `acceptsPTPCommands`. (Log 1 Nov 19:09–19:17.) *Live Stream (USB Streaming)*: not seen. **Photos:** Import appears but lists nothing with a RAW-only card; the cause is not yet known (Photos hiding ARW, or no files presented). | Wired tab screenshots, 1 Nov 18:55–18:59 |
| Device type mask that finds the camera (*Cameras, local*, *Cameras* or *System default*) | *Cameras, local* (mask in use 0x101) finds it in MTP, PC Remote and MSC. | Wired tab, 1 Nov |
| Contents and control authorisation on iOS 27: prompt shown, and the status returned | **No prompt** on iOS 27.2; both statuses return `authorized` (`contents=authorized control=authorized`). | Wired tab, 1 Nov; Shamil |
| Pass-through reply layout (`PTPPassThrough.Layout`) and whether transaction IDs are renumbered | **`dataThenResponse`**: the first value is the bare data phase (8 B for GetStorageIDs), the second the 12-byte response container. **Transaction IDs are renumbered**: the response carried 801 for our 1. | Log 1 Nov 19:19:37, MTP |
| `GetObjectHandles` allowed through `requestSendPTPCommand` | **Yes: 397 handles in 0.03 s** (ImageCaptureCore lists 391 files; the rest are folders or objects it hides). None matches an `ICCameraFile.ptpObjectHandle`, because they are all 0. GetStorageIDs gives one store, 0x00010001 *Storage Media*, no label: 255.94 GB, 242.57 GB free, free images 0xFFFFFFFF, storage type 4 (removable RAM), filesystem 2 (generic hierarchical), access 1 (read-only, no deletion). Fixtures on the phone: `usb/storageids.bin` (8 B), `usb/storageinfo.bin` (56 B), `usb/objecthandles.bin` (1,592 B). | Log 1 Nov 19:19:37–19:19:41, MTP |
| `GetPartialObject` variant that works (0x101B, 0x95C1 or neither) | **0x101B (32-bit) works** (advertised in MTP; 0x95C1 and Sony 0x9211 are not). DSC02018.ARW was reassembled in 4 MiB chunks at 37.29 MB/s and matches `requestReadData` and `requestDownload` by SHA-256 (see "Byte-range resume on USB"). Byte ranges work below 4 GiB only; a larger file has to be fetched whole. | GetDeviceInfo, 1 Nov 19:25, MTP; log 1 Nov about 23:00, build 0.1 (4.1) |
| `ObjectAdded` over USB: which code, delivered through `ptpEventHandler` or the delegate | **Not in *Image Transfer (MTP)* mode:** DeviceInfo lists 3 events, StoreAdded (0x4004), StoreRemoved (0x4005) and DevicePropChanged (0x4006); neither ObjectAdded 0x4002 nor Sony's 0xC201. The shutter is disabled in that mode anyway. *Remote Shoot (PC Remote)* is still to try. | GetDeviceInfo, log 1 Nov 22:59:37 and 23:37:51, MTP |
| Session survival on phone lock and app switch (seconds) | **The session survives; the transfer doesn't run.** Measured over USB in *Image Transfer (MSC)*. **Plain download (*Long serial download*):** After an app switch or a lock, at most the file already in flight completes, within about 1.7 s. Then nothing moves until the app is back in front, and ImageCaptureCore suspends its operations meanwhile. Every time, the same session carried on at once on return: no reconnect, no error, 40 MB/s again. That held after 144 s in another app and after locks of 18, 33, 43, 44, 161 and 227 s. The file that was in flight when the app left reports the whole time away (for example 37.9 MB in 144.9 s), so per-file rates after a return are not throughput figures. **Inside a continued task (`BGContinuedProcessingTask`, 20 ARW):** the download carried on with the phone locked. Files 4 to 20 (17 files, about 700 MB) came in at about 40 MB/s while locked, and the task finished (`finished=true expired=false`). So 1.0's USB imports should run inside a continued task. An import interrupted by the app leaving the foreground can simply carry on when it returns, because the session is still there. | Guided run *USB evening*, 2 Nov 11:29–11:51, build 0.1 (6.1), MSC: `usb.lifecycle.progressAfterBackground` 0.17 s (away 144 s), 15.48 s (continued task, away 81 s), 0.26 s (away 227 s), 0.00 s (away 18–161 s); `bgcontinued.ran` 20.81 s |
| `BGContinuedProcessingTask`: start latency, how long it ran, whether the system expired it, the system progress UI | **Camera-free timer test, 2 minutes, 1 Nov, Low Power Mode on:** the task started 0.03 s after the request, ran 136.25 s through a phone lock and finished; the system did not expire it. It finished while the app was still in the background, 9 s before the app returned to the foreground. While the task ran, the app logged lock and unlock events from the background; with no task (the earlier plain-background run) the suspended app logged none. So the process really kept running. In the background the half-second sleeps took about 0.57 s each on average (240 steps in 136 s instead of 120 s). Progress UI: the system showed its progress circle as a Live Activity (Shamil, on the phone). **10 minutes, same day, Low Power Mode off (status bar):** started 0.02 s after the request, ran 675.62 s and finished; the system did not expire it. The app stayed in the background for the whole run (853.7 s in all), while the phone was locked and unlocked several times. The steps again averaged about 0.56 s. Still to run: longer than 10 minutes (a full card over USB 2 takes longer), and around a real USB download (day 5). **Around a real USB download (2 Nov 11:40, MSC):** started 0.02 s after the request; 20 ARW (839 MB) in 20.8 s, 17 of them with the phone locked, at about 40 MB/s; finished, not expired. The 10-minute run is still to do. | Log, 1 Nov 15:08:05–15:10:30: `bgcontinued.startLatency` 0.03 s; `bgcontinued.ran` 136.25 s, finished=true expired=false; app in the background 142.4 s, locked 134.6 s. Log, 1 Nov 15:26:42–15:40:58: `bgcontinued.startLatency` 0.02 s; `bgcontinued.ran` 675.62 s, finished=true expired=false; app in the background 853.7 s |
| `requestDownload` completion string: file name or path | **A file name** (`DSC02018.ARW`), inside the downloads folder the request named. | Log 1 Nov 22:59:40.994, build 0.1 (4.1), MTP |
| `deviceDidBecomeReady(withCompleteContentCatalog:)` on a reopen of the same device |  |  |
| `ICCameraDevice.batteryLevel` compared with PTP BatteryLevel (0x5001) |  |  |
| `ICCameraItem.ptpObjectHandle` on iOS 27.2 (MTP; not in the plan) | **0 for every file** (the 5 newest logged). Day 4's ObjectInfo, partial read and resume steps can't take the handle from ImageCaptureCore, so they have to find it with `GetObjectHandles` and `GetObjectInfo`. | Log 1 Nov 19:05:19: `handle 0x00000000` on DSC02014–02018.ARW |
| DeviceInfo in MTP mode (not in the plan) | PTP 1.00; vendor extension 0xFFFFFFFF (plain MTP, no Sony extension), functional mode 0. **24 operations:** OpenSession, CloseSession, GetDeviceInfo, GetStorageIDs, GetStorageInfo, GetNumObjects, GetObjectHandles, GetObjectInfo, GetObject, **GetThumb 0x100A**, GetDevicePropDesc, GetDevicePropValue, 0x1016 SetDevicePropValue, **GetPartialObject 0x101B**, MTP 0x9801–0x9803 and **0x9805 GetObjectPropList** (one call can return every object's name, size and date), and 0x9280–0x9285 (unnamed). **Device properties (5):** 0x5001 BatteryLevel, 0xD402 DeviceFriendlyName, 0xD406 SessionInitiatorVersionInfo, 0xD407 PerceivedDeviceType, 0xD303. **Capture formats:** none. **Image formats (10):** 0x3001 Association, 0x300B, 0x3801 EXIF/JPEG, 0xB982 MP4, 0xB301 Sony MPO, 0x3000 Undefined, 0xB101 Sony ARW, 0xB310, 0x3008, 0xB110 Sony HEIF. Fixtures on the phone: `usb/deviceinfo.bin` (247 B, contains the serial), `usb/FIRMWARE` (14 B). | GetDeviceInfo, 1 Nov 19:25 |
| Listing the card over PTP (`usb.ptp.catalog`, not in the plan) | **No faster than ImageCaptureCore: 65.69 s** for 397 objects (391 files, 6 folders) against `usb.catalog.complete` 64.94 s on the same plug; GetObjectHandles 0.03 s plus 397 GetObjectInfo at about 165 ms each. The camera's GetObjectInfo is the bottleneck, and ImageCaptureCore's catalogue is almost certainly doing the same work. A 2,000-file card would take about 5½ minutes in MTP mode (MSC listed 391 files in 7.2 s). Reading newest-first (highest handle first) would show the latest shots within seconds. The listing gives real handles (0x00300103 … 0x00300123 for DSC02014–02018), parent 0x00300000, capture dates as `YYYYMMDDTHHMMSS`, format Sony ARW. | Log 1 Nov 21:14–21:16, build 0.1 (3.1) (spike build 4), MTP |
| MTP GetObjectPropList, whole card (`usb.mtp.proplist`, not in the plan) | **Not possible through ImageCaptureCore.** Both whole-card forms got no answer: libmtp's (every object, every property, depth 0xFFFFFFFF) at 21:16, and ObjectFileName only for every object at 23:00. Each came back as two empty pass-through values after about 60 s. At 21:16 the camera then answered nothing (every GetThumb and `requestThumbnailData` timed out) until it was replugged. At 23:00 the spike sent nothing more on that connection. If the camera builds the list at GetObjectInfo's pace (about 165 ms per object, 65 s for 397), it can't finish inside ImageCaptureCore's 60 s, so a card of any real size can't be listed in one request. | Log 1 Nov 21:16:44–22:09:47, build 0.1 (3.1); log 1 Nov 23:00:15–23:01:15, build 0.1 (4.1): `usb.mtp.proplist` 60.47 s, "ObjectFileName only, all objects, depth 0xFFFFFFFF; no answer", "no response container; first 0 B [], second 0 B []" |
| MTP GetObjectPropList, one object at a time (`usb.mtp.proplist.perObject`, `usb.mtp.listing`, not in the plan) | **Slower than GetObjectInfo: 385 ms per object on average** (10–800 ms), against about 165 ms, so listing the card this way took **152 s** against 66 s. **The 0.01 s seen at 23:00 was for the newest object**, which was also the fastest in both full listings (37–48 ms). The camera seems to answer its most recent file from memory. **No warm-up effect:** a second listing in the same session averaged 382.9 ms. **The newest 50 took 15.75 s** once the catalogue was complete. **Folders** add AssociationType (0xDC05) and AssociationDesc (0xDC0D). **PersistentUniqueObjectIdentifier:** sent for all 397 objects, 16 B each, all distinct. Identical for all 397 between two listings in one session, and again after a replug (23:49, "397 same, 0 changed"), so it can identify a file across sessions. Object handles were also the same after the replug. The camera's serial was not found in it as text or hex. The first single-object request, 1 Nov 23:00, answered in 0.01 s with 21 properties (336 B) for the newest object, DSC02018.ARW (0x00300123). The properties: StorageID, ObjectFormat, ProtectionStatus, ObjectSize, ObjectFileName, DateCreated, ParentObject, Name, **PersistentUniqueObjectIdentifier**, 0xDC81–0xDC84 (RepresentativeSample format, size, height and width), Width (0xDC87), Height (0xDC88), 0xDCD3, and five vendor properties (0xD8A1–0xD8A4, 0xD8A7). There is no DateModified. PersistentUniqueObjectIdentifier is MTP's 128-bit ID that stays the same across sessions, which could serve the import's "already imported" check. The `objectproplist-one.bin` fixture stays out of the repository (the pre-commit hook refuses it), because the IDs may carry the serial in a form the check doesn't recognise. | Log 1 Nov 23:00:15, build 0.1 (4.1); log 1 Nov 23:34:19–23:41:49, build 0.1 (5.1) |
| ImageCaptureCore's time limit on a pass-through request (not in the plan) | **About 60 s.** Then `requestSendPTPCommand` completes with two empty values and no error, and the spike was still waiting (its timeout was 90 s at 23:00 and 120 s at 21:16). The product has to treat an empty reply as "no answer" and keep every pass-through request well inside 60 s. | `usb.mtp.proplist` 60.47 s, log 1 Nov 23:01:15; 21:16 run |
| GetThumb over PTP (`usb.ptp.thumb.avg`, not in the plan) | **143.3 ms average** (min 35.6, max 337.6), 50 of 50, about 6 KB each, for the 50 highest handles on a fresh plug. All 50 came back with a thumbnail, so no folder was among the 50 highest handles. That is the same as ImageCaptureCore's `requestThumbnailData` (144.8 ms on the same card), so the camera, not ImageCaptureCore, sets the pace. Both miss day 2's 50 ms target, so thumbnails will need a cache and newest-first loading. The run was tapped 2 s after *Open session*, but its first command was only answered when the catalogue completed (see the next row). | Log 1 Nov 22:58:16–22:59:26, build 0.1 (4.1): `usb.ptp.thumb.avg`, `usb.catalog.complete.contended` |
| Pass-through while ImageCaptureCore's catalogue runs (not in the plan) | **It waits for the catalogue.** In MTP mode no PTP command from the app is answered until ImageCaptureCore has listed the whole card: 65 s for 391 files, and the catalogue grows with the card. **Build 6:** GetObjectHandles was sent 4.7 s after *Open session* and answered OK 60.24 s later, the moment the catalogue completed (65.05 s after the open). The next GetObjectPropList answered in 48 ms. **Build 5:** GetObjectHandles, sent about 2 s after the open, was answered 62.8 s later as the catalogue completed. **The wait isn't counted against ImageCaptureCore's 60 s limit**, since 62.8 s still got an answer. The limit applies to a command the camera is working on. **The catalogue's percentage stays at 0 %** for about 64 s, then jumps to complete within a second. So in MTP mode the app can't show even the newest file sooner by going to PTP itself. | Log 1 Nov 23:34:14–23:35:19, build 0.1 (5.1): "during ImageCaptureCore's catalogue: GetObjectHandles sent 4.7 s after Open session, answered OK 60241 ms later"; log 1 Nov 22:58:16–22:59:19, build 0.1 (4.1) |
| GetObjectInfo of an ARW and a JPG in MTP mode (not in the plan) | **DSC02018.ARW:** Sony ARW, 40,329,216 B, 7008 × 4672, image bit depth 0, captured `20261101T180520`, no modification date, thumbnail JFIF 6,584 B at 160 × 120, parent 0x00300000, sequence 0. **DSC01997.JPG** has the same layout (thumbnail 7,376 B). Both match ImageCaptureCore's name, size and date. The card has no RAW+JPEG pair, so the pairing check is still to run. Fixtures on the phone: `usb/objectinfo-arw.bin` and `usb/objectinfo-jpg.bin` (114 B each). | Log 1 Nov 22:59:34–22:59:36, build 0.1 (4.1) |
| ImageCaptureCore keeps the catalogue across app launches (not in the plan) | **While the camera stays plugged in, yes.** A relaunched app opened a session and got the complete catalogue of 391 files **0.09 s** after the open, against 65 s cold. After a replug the next open took the full 64.9 s again. So an import app that is relaunched (or comes back after being terminated) with the camera still connected can show the card at once. Build 7 records such an open as `usb.catalog.complete.kept`, not as a cold figure. | Log 1 Nov 23:46:19 (launch), 23:47:33 (`usb.catalog.complete` 0.09 s), 23:49:09 (64.90 s after the replug), build 0.1 (5.1) |
| Recovering after the build 5 stall (not in the plan) | **After the cable pull, ImageCaptureCore reported the removal** (`didRemove`, 23:02:11). But once browsing restarted, the camera didn't reappear in that run of the app (no `didAdd` in the next 50 s). After the app was relaunched at 23:34 it appeared at once. Build 6 never sends a whole-card request, so it shouldn't stall this way again. If a camera does stall, unplug it, or turn it off and on. | Log 1 Nov 23:01:15–23:03:21 and 23:34:12 |
| Shooting while connected over USB (not in the plan) | **The shutter is disabled in *Image Transfer (MTP)* and *Image Transfer (MSC)***: the camera is in a transfer-only state. Importing while shooting over USB needs *Remote Shoot (PC Remote)*; still to try. | Shamil, 1 Nov |
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
