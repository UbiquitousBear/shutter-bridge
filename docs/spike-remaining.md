# Rest of the spike: what to test, what to drop, and the MVP (from 2 Nov)

Written 1 Nov 2026 after spike build 6, from `docs/spike-plan.md`, `docs/proposal.md` and `docs/spike-findings.md`, and checked against them. It proposes; the decisions stay with Shamil and the 13 Nov go/no-go.

## Decisions (Shamil, 2 Nov)

- **Wireless is in 1.0.** The wireless go/no-go is no longer whether to ship it but which path works and how well. PTP/IP browsing on the camera's access point is the first choice; if no camera mode lists the card, the camera's *Send to Smartphone* is the path. Iteration 3 is in 1.0 either way, so both need testing: every camera Wi-Fi mode, the join and pairing flow, resume after a drop, behaviour under lock, and the fallback.
- **Battery per GB and MP4 are out of the spike.** 1.0 imports stills; nothing in it depends on battery use per GB.
- **Scaling is measured, not assumed:** the guided *Scaling* run lists the card cold in MSC (and MTP), adds a burst of about 300 frames, lists again, and projects 2,000 and 5,000 files from the two sizes.
- **More of the testing runs as guided runs** in the spike's *Guided* tab (build 8), so each evening needs fewer builds and less reading of the runbook.

## What I checked against the repo, and what changes the inputs

- **Build 7** (PR #14) adds the requestReadData resume for MSC and fixes two false readings. The phone runs spike build 6 (TestFlight 0.1 (5.1)). Merging build 7 and running *Spike to TestFlight* is the first step.
- **The Wi-Fi tab already has every day 6–9 button**, and has had them since the first build, though none has been run against the camera yet: Join camera Wi-Fi, QR scan, the TCP/Bonjour/SSDP probes, Connect + OpenSession + GetDeviceInfo, List card, Thumbnails, GetObject 20 ARW, Shutter test, resumable read and the GUID buttons. So the wireless answer needs **no new build and no Mac**. You can get it on the phone on Tuesday 3 Nov instead of 9–11 Nov. The Mac probes are only needed to diagnose a failure.
- **Two lifecycle buttons cover different lengths.** *Long serial download* fetches all 231 ARW (9.8 GB, about 4 min). *Download 20 newest ARW inside a continued task* runs for only about 21 s. Build 7 can therefore measure a plain lock over 4 min, but not a long continued task around USB. Even all 231 ARW take only about 4 min at 40 MB/s, so a 10-minute continued run in build 8 has to loop or include the JPGs.
- **The wireless fallback has not been tested either.** The plan's "otherwise" is the camera-side *Send to Smartphone* (`Select on Camera & Send`), and nothing in the spike checks whether a third-party app can receive it. If PTP/IP doesn't list the card, that is the next thing to try.
- **The proposal's own exit criterion for background import is small.** "Lock the phone during a 2 GB import" is about 50 s at 40 MB/s. A plain lock run of 4 min already covers it.

---

## 1. What the spike still has to answer for 1.0, ranked

Only the open items whose answer changes what 1.0 builds or whether it ships are listed here.

| # | Question | Decision it feeds | Smallest test | If it isn't run, assume |
|---|---|---|---|---|
| 1 | **Does any Wi-Fi mode list the card over PTP/IP at ≥ 8 MB/s on the camera's access point?** | Whether wireless browsing is in 1.0 (Iteration 3). Iterations 3 and 4 run in parallel in weeks 10–13, so this changes who builds what, not the 15 weeks. | Phone only, build 7. Camera on *Smartphone Connect*. Join the camera's Wi-Fi, run the TCP 15740 probe, then *Connect + OpenSession + GetDeviceInfo*, *List card* and *GetObject 20 newest ARW*. If that fails, repeat in *PC Remote*, *Wi-Fi Direct*. About 45 min. | No wireless browsing in 1.0. Wireless in 1.0 becomes the camera-side *Send to Smartphone* flow, if 1b works. |
| 1b | Only if 1 fails: **does *Select on Camera & Send* reach our app?** | Whether 1.0 has any wireless path at all. | Camera: `Select on Camera & Send` with 2 frames chosen. Phone: Connect, then *List card*. Does it list only the chosen objects? About 10 min. | 1.0 is wired only. |
| 2 | **Does a USB download keep going when the phone locks or you switch apps? Does a continued task keep it alive?** | Goal 4. Whether every USB import must run inside `BGContinuedProcessingTask` from Iteration 1 (not 4), or whether the UI has to say "keep the app open". | Build 7, MSC. Run *Long serial download*, switch apps for 3 min, then do the same with a plain lock run (last). Build 8: a continued task that loops over the card (or includes the JPGs), locked for 10 min or more. | The plain session dies on lock. The continued task is mandatory. Goal 4 is at risk for wired. |
| 3 | **Can MSC resume and identify files after a replug?** (requestReadData at an offset, `usb.readData.resume.verified`; does ImageCaptureCore's name, size and date, and the device UUID tag, match after the replug?) | MSC or MTP as the wired mode. The shape of the identity ledger in MSC. | Build 7, MSC. Start a resumable requestReadData read, pull at PULL NOW, replug, Open session, Resume. Compare the UUID tag before and after. About 12 min. | MSC restarts the interrupted file from zero. For a 40 MB still that is about 1 s, so **this doesn't block choosing MSC**. Identity is folder, name, capture date and size. |
| 4 | **How does the camera name and describe a RAW+JPEG (or RAW+HEIF) pair?** | The pairing rule in PhotosBridge (Iteration 1). | Shoot 3 RAW+JPEG and 2 RAW+HEIF frames. Run *GetObjectInfo: newest ARW + pair* in MTP, and read the 5-newest log lines in MSC. About 10 min. | Pair by same folder, same stem and capture time within 1 s. |
| 5 | **Does the camera advertise a stable BLE service UUID, at least while it is on?** Does a locked phone get the reminder? | Goal 6 (proximity reminder in 1.0) or its fallback. | Bluetooth tab. On, asleep and off with *Creators' App quit* (our users' usual state) and once *not paired*; one connected run for comparison. The UUID has to be advertised: one found only through *List services (GATT)* can't be used, because iOS background scanning filters on advertised service UUIDs. Then *Watch in background* on a locked phone, same room and next room. About 60 min. | The plan's fallback: a reminder that works only while the camera is on, or a Shortcuts automation on the home Wi-Fi. |
| 6 | **Can the camera's USB mode be fixed, so it stops asking *Select USB Connect Mode* on every plug?** | Auto-import on connect (Iteration 4) and the empty-state and setup copy. | Camera menu `Setup → USB → USB Connection Mode`. Record the choices. About 2 min. | Auto-import needs a mode pick on the camera every time. Move it out of 1.0. |
| 7 | **Thumbnails: does concurrency help, and is the embedded preview cheaper over requestReadData in MSC?** | The Browse pipeline and the "first screen in 1 s" budget. | Build 8. requestThumbnailData with 2 and 4 in flight. In MSC, requestReadData of the first 256 KB, then an ImageIO thumbnail. About 10 min. | Serial loading at 150–190 ms each, a disk cache and visible-first loading. The budget becomes "first 12 tiles in about 2 s". |
| 8 | Only if 1 passes: **QR scan and join, GUID persistence and camera prompts** | The pairing and join UX in Iteration 3. | Same evening as 1. QR scan → Join camera Wi-Fi gets you onto the network anyway. Then power-cycle and reconnect with the same GUID, then a new GUID. About 20 min. | Typed password, and a pairing prompt every time. |
| 9 | **Submit the multicast entitlement request.** Does the camera answer SSDP? | SSDP discovery. | No test for the request: 15 min on Apple's form. For the go/no-go, count the camera's reply to the phone's unicast M-SEARCH as the evidence, or keep one Mac capture of UDP 1900 and the `ssdp-description.xml` fixture. | Not granted by 13 Nov. Typed IP, the camera access point's gateway and Bonjour are enough on the camera's own network. |
| 10 | **Photos access when the person says *Don't Allow*, and after declining the first prompt (needs a fresh install).** | The Photos permission flow in Iteration 1. | Photos tab, about 10 min, any evening. | Treat *Don't Allow* as "import to Files only" and explain in the UI. |

Cheap yes/no checks that fit into a session already planned, but don't change 1.0:
- *Remote Shoot (PC Remote)* over USB, with ObjectAdded (one plug, 10 min).
- Wi-Fi ObjectAdded (*Shutter test*, 1 min).
- Photos › Import with a JPG on the card (3 min).
- One UniFi LAN throughput figure.

## 2. Drop or defer

| Item | Why |
|---|---|
| All MP4 rows (USB, AP, LAN), the 1 GB clips, the 4 GiB / 0x95C1 question | 1.0 is stills only (proposal non-goals). |
| 2,000-file card in MTP | MTP costs a steady 165 ms per object, so the scaling is already clear. A 2,000-file MSC run is optional, and only worth it if a burst onto a spare card is cheap. |
| More MTP listing experiments (GetObjectPropList variants, PTP listing) | The conclusion is firm: 65 s, and the camera sets the pace. The MTP experiments cost builds 3 to 6. |
| Instruments Allocations, the Energy gauge | 70 MB against a 150 MB budget. The in-app sampling is enough. |
| Mac gphoto2 / Image Capture USB probes (day 1) | The iPhone's GetDeviceInfo is already captured. They are diagnostics only. |
| Mac day-6 probes as a required step | The phone runs the same chain. Run gphoto2, nmap or tcpdump only if the phone fails to tell an app bug from camera behaviour, plus one SSDP capture if the camera is already on the network. |
| Sony SDIO experiment | Only explains PC Remote listing. Not a go/no-go input. |
| LAN lock, resume, battery and events; Wi-Fi two in flight | The same protocol as the access point. Record one LAN throughput only. |
| Battery per GB (all links) | No 1.0 feature depends on it. Run it only if a USB evening has 5 spare minutes. Over Wi-Fi it needs 1 GB, more than *GetObject 20 newest ARW* (839 MB) moves, so it isn't recorded as a side effect. |
| BLE: all 9 power × pairing combinations | On, asleep and off with Creators' App quit, plus one *not paired* and one connected run, answer the go/no-go. The next-room check is part of the proximity test. |
| The Photos Import RAW-only mystery | Not our app's path. One JPG check covers the plan criterion. |
| A second MTP lifecycle run | Lock behaviour sits in ImageCaptureCore and iOS, not in the camera's mode. Run it in MSC only, unless MTP is still the candidate after evening 1. |

In the findings, mark every dropped cell of the plan's measurements table "skipped (stills-only 1.0)" or "skipped (not a 1.0 decision)" rather than leaving it blank.

Saving: about 4–5 hours of hands-on time, and the wireless answer arrives about six days earlier.

## 3. Speeding up the next batches

| Change | How | Saving |
|---|---|---|
| **Phone first for Wi-Fi** | Get the day 6–9 answers with build 7 on 3 Nov. Use the Mac (from Thu 5 Nov) only for diagnosis and fixtures. | About 1.5 h of Mac probes; the wireless scope known 6 days earlier |
| **One plug per mode** | Order MSC → PC Remote → MTP. Do all of MSC (resume pull, identity, lifecycle) in one plug, since MSC lists in 7 s. Do MTP last and pay the 65 s catalogue only once, then leave the camera plugged in, because the kept catalogue opens in 0.09 s. Try installing the TestFlight update while the camera stays plugged in; the kept catalogue may survive it. | About 5–8 min per evening, and fewer stalls |
| **One Wi-Fi join serves days 6–9** | Scan QR → Join camera Wi-Fi gets you onto the network and also covers the day-9 join and QR rows. Then run the probe, handshake, list, thumbnails, GetObject and shutter on the same join. NWPath comes for free. | About 30 min |
| **Preload the card once** | Shoot the RAW+JPEG and RAW+HEIF frames in session 0, with the cable out. Optional: a spare card with about 60 burst frames for PC Remote and MTP plugs, which cuts the 65 s catalogue to about 10 s. | About 5 min per MTP or PC Remote plug |
| **Leave the slow parts running on their own** | The long plain-lock run (4 min) and the build-8 continued task over all ARW (5–15 min) run while you fill in findings. Leave the BLE proximity watch on overnight and do the "camera switched on" checks at breakfast (2 min each, the phone locked in the next room). | About 45 min of evening time |
| **At most one more build (8)** | Build 7 now. Build 8 only after the first Wi-Fi evening, carrying everything in one go: Wi-Fi fixes, the thumbnail experiments (items 7), a continued task over all ARW, and a session report. Push it the night before, so it is installable the next evening. | About 2 h of builds and installs compared with one build per finding |
| **Copy, don't screenshot** | Build 6 already has *Copy log since the last Open session* and *Copy whole log*. Build 8 adds *Mark session start* and *Copy since the mark*, for Wi-Fi and BLE sessions that have no USB *Open session*. | About 10 min per evening, and fewer misread cells |
| **Light runner, Wi-Fi only** | Build 8: a *Wi-Fi chain* button (probe → handshake → list → thumbnails 50 → GetObject 20 ARW → 20 s shutter) for repeats on PC Remote and on the LAN. On USB a runner gains little, because each remaining step needs a hand: a cable pull, a lock or a shutter press. | About 10 min per extra mode or network |
| **CI instead of the phone** | Once fixtures are committed, the PTPKit decode tests run on Linux in CI. Writing up from the shared log can be done by me. | Removes rereading log output during findings write-up |

Overall: the remaining hands-on time falls from about 13–14 h to about 6 h of tests plus about 2.5 h of docs, and all data is in by Fri 6 Nov or Mon 9 Nov. That leaves 9–12 Nov as a buffer.

## 4. Session plan

**S0 · Mon 2 Nov, daytime (25 min, no camera session)**
1. Merge the build 7 PR and run *Spike to TestFlight* (about 25 min of waiting, unattended).
2. Submit the multicast entitlement request and note the date and reference.
3. Camera, cable out: shoot 3 RAW+JPEG and 2 RAW+HEIF frames.
4. Menu `Setup → USB → USB Connection Mode`: can it be fixed (item 6)? Record that wording, `Version`, `USB Power Supply` and `USB LUN Setting`.
5. Fill in the Setup rows (card type and kinds, cable). Charge both batteries.

**S1 · Mon 2 Nov evening: wired, build 7 (about 70 min hands-on, 90 min elapsed)**
1. **Plug 1, MSC:**
   - Photos › Import, before opening the app. Does the JPG show? Then close Photos.
   - Open session (a second cold MSC listing).
   - requestReadData resume: pull at PULL NOW, replug in MSC, Open session, Resume. Get `usb.readData.resume.verified` and compare the UUID tag.
   - Note the pair stems in the 5-newest lines.
   - Lifecycle: *Long serial download* and switch apps for 3 min. Then the 20-ARW continued task and lock. Then *Long serial download* with a plain lock for 5 min, last.
2. **Plug 2, Remote Shoot (PC Remote):** Open session (record the time and capabilities), *GetDeviceInfo*, *Watch for ObjectAdded (60 s)*, and press the shutter 2–3 times. 10 min. Stop if the session won't open.
3. **Plug 3, MTP:** *GetObjectInfo: newest ARW + pair*. Leave the camera plugged in.
4. Share the log.

**S2 · Tue 3 Nov evening: Wi-Fi on the camera's access point, build 7, phone only (about 75 min)**
1. Camera: `Network → Cnct./PC Remote → Smartphone Connect` (record the wording).
2. *Scan camera QR code* (record the field names), then *Join camera Wi-Fi* (`ptpip.ap.join`, and note when the Local Network prompt appears), then *Use gateway as camera IP*.
3. Day 6 probe: TCP 15740, Bonjour, SSDP unicast, and multicast once (a policy failure is expected).
4. *Connect + OpenSession + GetDeviceInfo* (photograph the camera screen), *List card*, *Thumbnails 50*, *GetObject 20 newest ARW* (battery before and after), *Shutter test (20 s)*.
5. Power-cycle the camera and *Reconnect (same GUID)*. Then *New GUID* and connect. Note the prompts.
6. Whatever step 4 gives, run steps 3–4 in *PC Remote* over the access point and in *Wi-Fi Direct* (pair on the camera) too: the day-6 mode matrix is a deliverable with all three rows. If none lists the card, try 1b.
7. If listing works: the resumable read with Wi-Fi off at 50 % (day 9's pass criterion and Iteration 3's exit). Not optional if wireless is a go.
8. Share the log. The wireless go/no-go is known that night.

**S3 · Wed 4 Nov evening: BLE, build 7 (about 60 min)**
1. Creators' App paired but quit. Camera On, Asleep and Off: *Scan (Sony only)* for 30 s, *Stop and summarise* and *Save snapshot* in each state. Then one run not paired, and one with Creators' App connected, for comparison.
2. Choose the filter UUID from what is advertised. *List services (GATT)* only explains what a UUID is; background scanning can't use one that isn't advertised.
3. Fill the Bluetooth menu rows.
4. *Watch in background*, phone locked: same room, then next room.
5. Leave the watch on overnight. On Thu and Fri mornings, switch the camera on with Creators' App quit, and after *Kill app to test relaunch*. 2 min each.

**S4 · Thu 5 Nov evening: Mac (about 75 min)**
1. `brew install xcodegen gphoto2 nmap`, then `make hooks`.
2. Share the fixtures zip from the phone (Log › Fixtures), AirDrop it, `ditto` it into `Fixtures/a7c2`, then `make fixtures` and `make test`, and commit on a branch.
3. Only if S2 failed or was unclear: gphoto2, nmap and tcpdump on the failing mode, to tell an app bug from camera behaviour. Optionally one SSDP tcpdump capture.
4. Settle what goes into build 8 and push it that night.

**S5 · Fri 6 Nov or the weekend: build 8 (about 60 min)**
1. Wi-Fi retry, if needed, with the chain button.
2. UniFi LAN: `Access Point Set.`, 5 GHz, then the chain once for a throughput figure.
3. Thumbnail concurrency and MSC header-read timings.
4. The continued task looping over the card with the phone locked for 10 min or more (unattended).
5. Re-share the fixtures if any new ones arrived (pair ObjectInfo, ptpip, events).

**Mon 9 – Tue 10 Nov:** buffer for repeats only.

**Wed 11 – Fri 13 Nov (about 2.5 h of docs):**
- *Copy measurements table*, the six go/no-go rows, the proposal's transport table, budget and roadmap.
- Revise `docs/iteration-1-backlog.md`.
- Confirm that nothing from `Spike/` goes into production.
- Decision on 13 Nov. The production workspace stays unstarted until then.

## 5. Build vs MVP: stop, decide now, reshape

**The spike should stop building:**
- MTP listing variants and PTP thumbnail variants.
- Any resume engine, catalogue or import queue (that is MVP work).
- New Wi-Fi features beyond the fixes from S2.
- BLE wake and GATT work beyond listing service UUIDs.

Build 8 is the last build unless S5 finds a blocker.

**Recommendations that can be taken now.** Write them into the 13 Nov decision record; don't start production code before then.

1. **Wired mode: support both, and recommend *Image Transfer (MSC)* in the app's copy. Branch on transport type, not on `acceptsPTPCommands`.**
   - Evidence: MSC lists 391 files in 7.2 s against 65 s for MTP. JPGs come at 41.7 MB/s against 25.6, and 25.6 MB/s misses goal 2's ≥ 30 MB/s wired target, so the copy and the budget have to allow for JPGs over MTP. The camera asks for a mode on every plug, so users will pick either one.
   - Overturned if: MSC listing scales badly (2,000 files over about 60 s), MSC identity is unstable across a replug (S1), or MSC loses data that 1.0 needs.
2. **One import path in both modes: `requestDownloadFile`, plus requestReadData at an offset for resume. GetPartialObject is not the download method.**
   - Evidence: requestReadData runs at 41.1 MB/s against 37.3 for GetPartialObject, takes an offset, and is the only option in MSC.
   - Overturned if: build 7's MSC resume fails. Even then, per-file restart is fine for stills.
3. **Byte-range resume is low priority for wired stills.**
   - A 40 MB ARW restarts in about 1 s at 40 MB/s. "Skip what is already imported, restart the interrupted file" meets goal 3 over USB.
   - Keep `.part` and byte resume for Wi-Fi (5 s per ARW at 8 MB/s) and for video later.
   - Iteration 2 shrinks accordingly.
   - Iteration 2's exit criterion "re-plugging after a pull resumes within 2 s" can't be met: after a replug, nothing answers until the catalogue is done (about 65 s in MTP, about 7 s in MSC). Rewrite it as "resumes as soon as the camera is listed again".
4. **One download at a time on USB.**
   - Evidence: two in flight gains 2–5 %.
   - Overturned if: a USB 3 phone shows otherwise.
5. **Our own catalogue cache is the answer to goal 1.**
   - Show the last-known card at once and mark it provisional while ImageCaptureCore lists, with progress (65 s in MTP, 7 s in MSC). The kept catalogue (0.09 s) covers relaunches while the camera stays plugged in.
   - Rewrite the goal as "camera visible in 2 s; last-known card at once; full listing in about 10 s in MSC".
   - Overturned if: some mode lists far faster (PC Remote, Wi-Fi).
6. **Thumbnails: requestThumbnailData, serial, visible tiles first, disk-cached by identity.**
   - Budget: about 150–190 ms per thumbnail.
   - Overturned if: build 8 shows concurrency or MSC header reads under 50 ms.
7. **Identity:** in MTP, `PersistentUniqueObjectIdentifier` (stable across a replug and unique). In MSC, folder, name, capture date and size. The camera key is the DeviceInfo serial when PTP is available, otherwise a single "USB camera" record (fine with one camera in 1.0).
   - Overturned if: S1 shows ImageCaptureCore's MSC dates or names change across a replug.
8. **Photos access:** ask for read/write and accept Limited with nothing selected. Stage files complete-until-first-unlock.
   - Measured, except *Don't Allow* and a declined first prompt (item 10).
9. **Test seam: simulate at the level of a camera store (list, read range, thumbnail, removal), not with PTP bytes.**
   - One fake then covers MSC, MTP and PTP/IP.
   - PTPKit stays for the MTP extras (serial, battery, storage) and for PTP/IP. If wireless is a no-go, PTPKit and the PTP simulator drop out of Iteration 1's critical path.
10. **Pending, then decided:**
    - Background: if S1 or S5 show that a lock kills the USB session, every import runs inside a continued task, moved from Iteration 4 to Iteration 1.
    - Wireless: if S2 fails and 1b works, 1.0's wireless is the *Send to Smartphone* flow; only if 1b fails too is 1.0 wired only. Iterations 3 and 4 run in parallel, so this changes staffing in weeks 10–13, not the length of the plan.
    - Auto-import: if the USB mode can't be fixed, auto-import drops from 1.0.
    - Proximity reminder: if no advertised UUID is stable at least while the camera is on, 1.0 falls back to the Shortcuts automation on the home Wi-Fi.

**Out of scope for 1.0, kept as yes/no checks only:** video, transfer-while-shooting (ObjectAdded), BLE wake, SSDP multicast, USB 3, battery per GB.