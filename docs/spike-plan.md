# Spike plan — weeks 1 and 2

Oct 31, 2026 · Shamil · Live copy: https://claude.ai/artifact/S9gWVRBNxFB63Qe2B1GbzT#f0256c11-aace

Ten working days from Monday 3 November 2026 (go/no-go on Friday 13 November), one engineer, one α7C II and one base-model USB-C iPhone, to answer four questions before any production code is written: what the camera exposes over USB to `ImageCaptureCore`, whether `GetPartialObject` works there, what it exposes over PTP/IP on Wi-Fi, and what the real throughput is on each link. Week 1 is wired, week 2 is wireless, day 10 is the go/no-go.

## Prerequisites (stage before day 1)

| Item | Requirement | Why |
| --- | --- | --- |
| Camera | α7C II on firmware 2.00 or later (check `Setup → Setup Option → Version`); a UHS-II card with a mixed set of about 200 files: ARW, ARW+JPG pairs, HEIF, 4K XAVC HS clips | Firmware 2.00 is Sony's floor for differential transfer; the mixed card exercises every format path |
| iPhone | Base-model USB-C iPhone on iOS 27.0 or later, Developer Mode on, at least 20 GB free | USB 2 bus is the bench ceiling (\~35 MB/s) |
| Cable | USB-C to USB-C, data-rated (USB 3.2 Gen 1 or better, no charge-only cable) | A charge-only cable fails silently as "no device" |
| Mac | Apple-silicon Mac with Xcode 27, `libgphoto2` (`brew install gphoto2`), Wireshark or `tcpdump`, `nmap` | Mac-side probes are the cheapest way to see what the camera exposes before writing Swift |
| Network | Camera's own access point, and the home UniFi network on a 5 GHz SSID with multicast (mDNS/SSDP) allowed between the camera and phone VLANs | Both Wi-Fi setups are in scope for 1.0 |
| Apple accounts | Developer account; multicast entitlement request submitted on day 1 (turnaround is days to weeks) | Blocks SSDP discovery in TestFlight builds, not the spike |
| Repo | Empty `ShutterBridge` repository with a `Spike/` folder and an `Xcode Cloud` workflow stub; a `Fixtures/` folder for captured bytes | Nothing in `Spike/` is production code; fixtures are kept |

**Camera menu paths to confirm on day 1** (names below are from the α7 IV-generation menu system that the α7C II shares; verify each against the α7C II help guide and note the exact wording in the findings):

- USB: `Setup → USB → USB Connection Mode` — candidates *Select on Connect*, *Still Img Transfer (MTP)* (older naming *MTP*), *Remote Shoot (PC Remote)*, *Webcam*. Also `Setup → USB → USB LUN Setting` and `USB Power Supply`.
- Wi-Fi: `Network → Wi-Fi → Wi-Fi Connect`, `Network → Wi-Fi → Access Point Set.` (registers the home SSID), `Network → Wi-Fi → Wi-Fi Frequency Band` (force 5 GHz).
- Phone pairing: `Network → Cnct./PC Remote → Smartphone Connect` (shows the QR code and SSID/password); `Network → Cnct./PC Remote → PC Remote Function` with *PC Remote Cnct Method* = *Wi-Fi Direct* or *Wi-Fi Access Point*, and *Pairing*.
- Transfer: `Network → Transfer/Remote → Select on Camera & Send` (the camera-side *Send to Smartphone* flow used as the wireless fallback).

## Week 1 — wired (USB-C)

Day 1 answers the biggest wired question with no code at all: if the built-in Photos app can import from the camera, `ImageCaptureCore` can open it too.

| Day | Goal | Steps | Pass criterion |
| --- | --- | --- | --- |
| 1 · Mon 3 Nov | Baseline with zero code | Set each USB mode in turn, plug into the iPhone, open Photos → Import; on the Mac open Image Capture and run `gphoto2 --auto-detect` and `gphoto2 --summary`; record which mode enumerates, the device name, and the operations list `gphoto2` prints. Create the Xcode 27 project, add the external-camera usage string, start an `ICDeviceBrowser` and log `didAdd`. Submit the multicast entitlement request. | Photos imports at least one JPG; `ICDeviceBrowser` reports the α7C II with `ICDeviceCapability` flags logged |
| 2 · Tue 4 Nov | Enumerate the card | `requestOpenSession`, walk `contents` / `mediaFiles`, log count, names, sizes, dates, `ptpObjectHandle`; time a full listing of the 200-file card and of a 2,000-file card if available. Fetch `requestThumbnailData` for 50 items and time it. | Listing of 200 files ≤ 2 s; thumbnails ≤ 50 ms each on average; metadata matches the card |
| 3 · Wed 5 Nov | Download and throughput | `requestDownloadFile` for 20 ARW, 20 JPG, 3 MP4; measure MB/s per type with `ContinuousClock`, memory with Instruments (Allocations), CPU with the Energy gauge. Repeat with two downloads in flight. | Sustained ≥ 25 MB/s on the USB 2 iPhone; high-water memory ≤ 150 MB |
| 4 · Thu 6 Nov | PTP pass-through | `requestSendPTPCommand` with hand-built containers: `GetDeviceInfo` (parse the supported-operations and vendor-extension lists), `GetObjectInfo`, `GetPartialObject` in 4 MiB chunks to reassemble one ARW; compare its MB/s to day 3. Press the shutter with the session open and log `didReceivePTPEvent` to see whether `ObjectAdded` (0x4002) arrives in MTP mode. | `GetPartialObject` returns correct bytes (SHA-256 equals the card copy); throughput within 15 % of `requestDownloadFile`; event behaviour recorded either way |
| 5 · Fri 7 Nov | Lifecycle and fixtures | Lock the phone and switch apps during a download: does the session survive, and for how long? Wrap a download in `BGContinuedProcessingTask` and repeat. Capture raw PTP request/response bytes from days 2–4 into `Fixtures/a7c2/usb/`. Write the week-1 findings page. | Behaviour on lock documented with timings; fixtures committed; findings written |

## Week 2 — wireless (PTP/IP)

Day 6 is again code-free: Mac-side probes establish which camera mode opens a PTP/IP responder and whether it lists the card, before any Swift is written.

| Day | Goal | Steps | Pass criterion |
| --- | --- | --- | --- |
| 6 · Mon 9 Nov | Find the responder | For each of *Smartphone Connect*, *PC Remote over Wi-Fi Direct* and *PC Remote over Access Point*: join from the Mac, run `tcpdump -i en0 udp port 1900` to capture SSDP, `nmap -p 15740 <camera ip>`, then `gphoto2 --port ptpip:<camera ip> --summary` and `--list-files`. Record for each mode: port open, handshake accepted, whether on-card objects are listed or only tethered captures. Then capture the camera's BLE advertisement with nRF Connect or LightBlue with the camera on, asleep and powered off (Bluetooth Function on, Remote Power ON/OFF on): note the advertised service UUIDs, manufacturer data and interval, and whether the phone can see it from the next room. | A table of mode → (SSDP yes/no, 15740 open yes/no, card listed yes/no). This row decides wireless scope. BLE advertisement recorded in all three power states, with the service UUID the proximity reminder will filter on |
| 7 · Tue 10 Nov | Swift PTP/IP handshake on the iPhone | `NWConnection` to port 15740: `Init_Command_Request` (GUID + friendly name) → `Init_Command_Ack`, second connection `Init_Event_Request` → `Init_Event_Ack`, then `OpenSession`, `GetDeviceInfo`, `GetStorageIDs`. Power-cycle the camera and reconnect with the same GUID; then with a new GUID. Note what the camera asks on screen each time. | Session opens from the iPhone; GUID persistence recorded (no prompt / prompt once / prompt every time) |
| 8 · Wed 11 Nov | Enumerate and download over Wi-Fi | `GetObjectHandles`, batched `GetObjectInfo`, `GetThumb` for 50 items, `GetObject` for 20 ARW and 3 MP4; measure MB/s on the camera's AP (5 GHz, phone 1 m away) and on the UniFi LAN. Check `NWPath` for the phone's internet loss on the camera AP. | Listing of 200 files ≤ 5 s; ≥ 8 MB/s on the camera AP; LAN figure recorded |
| 9 · Thu 12 Nov | Resume, discovery and the join flow | `GetPartialObject` chunked download; kill Wi-Fi at 50 % and reconnect: resume from offset and verify SHA-256. SSDP `M-SEARCH` from the iPhone with `NWConnectionGroup` (needs the entitlement; if it has not arrived, test on the Mac and use a typed IP on the phone). Scan the camera's QR with `DataScannerViewController`, decode the SSID/password, join with `NEHotspotConfiguration`, observe the Local Network prompt. | Resumed file is byte-identical; the join flow completes end to end without typing a password |
| 10 · Fri 13 Nov | Go / no-go | Fill the measurements table, run the criteria below, update the proposal's transport table and roadmap, write the Iteration 1 backlog. Decide wireless scope for 1.0. | Decision recorded in the proposal with the numbers behind it |

## Measurements and go/no-go criteria

Every number below is filled in on day 10; the proposal's performance budget is then corrected to what was measured, not what was hoped.

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

**Go/no-go on day 10**

| Question | Go if | Otherwise |
| --- | --- | --- |
| Wired import is viable | `ImageCaptureCore` enumerates the card in some USB mode and sustains ≥ 25 MB/s | Stop: the product has no sanctioned transport on iPhone |
| Byte-range resume on USB | `GetPartialObject` works through `requestSendPTPCommand` | Resume per file only (restart the interrupted file); note in the engine design |
| Wireless browsing in 1.0 | A camera mode lists on-card objects over PTP/IP and sustains ≥ 8 MB/s on the camera AP | Wireless in 1.0 becomes the camera-side *Send to Smartphone* flow; full browsing moves to 1.1 |
| SSDP discovery | Entitlement granted and the camera announces | Typed-IP and mDNS only; revisit when the entitlement lands |
| Transfer-while-shooting feasible later | `ObjectAdded` arrives on at least one link | Remove it from the post-1.0 list |
| Proximity reminder in 1.0 | The camera advertises a stable service UUID, at least while on, that iOS background scanning can filter on | Reminder works only with the camera switched on, or falls back to a Shortcuts automation on the home Wi-Fi SSID |

## Deliverables

- [ ] Findings page: one paragraph per question, the exact α7C II menu wording observed, and the filled measurements table
- [ ] `Fixtures/a7c2/usb/` and `Fixtures/a7c2/ptpip/`: captured `DeviceInfo`, `ObjectInfo` and event containers, plus one full `GetPartialObject` reassembly with its SHA-256
- [ ] Mode matrix from day 6 (camera mode → SSDP, port, card listing)
- [ ] Go/no-go decision recorded in the proposal, with the transport table, performance budget and roadmap updated to match
- [ ] Iteration 1 backlog: `PTPKit` container types, `USBLink` surface, catalogue schema, the three screens
- [ ] Multicast entitlement request submitted (day 1) and its status noted
- [ ] Throwaway spike app archived in `Spike/`, not carried into the production target
