# Rest of the spike: what remains before the product build (from 4 Nov)

Written Wednesday 4 Nov 2026 on spike build 14 (TestFlight 0.1 (14.1)). It rests on `docs/spike-findings.md`, including the home-network runs of 4 Nov 03:23–03:41 (not yet on `main`), `docs/spike-plan.md`, `docs/spike-runbook.md` and `docs/proposal.md`. It proposes; the decisions stay with Shamil and the 13 Nov go/no-go.

## Decisions (Shamil, 2 Nov)

- **Wireless is in 1.0.** The wireless go/no-go is no longer whether to ship it but which path works and how well. PTP/IP browsing on the camera's access point is the first choice; if no camera mode lists the card, the camera's *Send to Smartphone* is the path. Iteration 3 is in 1.0 either way, so both need testing: every camera Wi-Fi mode, the join and pairing flow, resume after a drop, behaviour under lock, and the fallback.
- **Battery per GB and MP4 are out of the spike.** 1.0 imports stills; nothing in it depends on battery use per GB.
- **Scaling is measured, not assumed:** the guided *Scaling* run lists the card cold in MSC (and MTP), adds a burst of about 300 frames, lists again, and projects 2,000 and 5,000 files from the two sizes. (The burst was dropped on 3 Nov; see below.)
- **More of the testing runs as guided runs** in the spike's *Guided* tab (build 8), so each evening needs fewer builds and less reading of the runbook.

## Decisions (Shamil, 3 Nov)

- **Dropped:** *Smartphone Connect* (the Bluetooth switch-on is that connection), *Send to Smartphone* (the fallback isn't needed: the camera lists its card over PTP/IP), the RAW+JPEG / RAW+HEIF pairing test (Shamil shoots RAW only; the pairing rule stays the default: same folder, same stem, capture time within 1 s), and the 300-frame *Scaling* burst (projected from the listings already made; see *Wireless browsing in 1.0* in the findings).
- **Still to run (as of 3 Nov):** PC Remote over the home Wi-Fi, resume in MSC, PC Remote over USB, a real proximity arrival, *Copy all RAW to Files* over USB-C, the build 14 Bluetooth and copy runs, and Photos *Don't Allow* (last, on a fresh install). On 4 Nov the home-network runs, the USB-C copy and the build 14 runs were done. What is left of this list, and what has come up since, is in section 2.

---

## 1. Where the spike stands

Every go/no-go row of the plan has an answer. Nothing below is waiting on a run to reach a decision on 13 Nov; the open runs settle details of 1.0 and complete the record.

| Question | Answer on 4 Nov | Findings section |
| --- | --- | --- |
| Wired import is viable | **Go.** MSC lists 391 files in 7.2 s (547 in 11.6 s) and downloads ARW at 39.9–41.7 MB/s. MTP downloads at 38–39 MB/s but takes 65 s to list, and JPG runs at 25.6 MB/s against 41.7 in MSC. The goal is ≥ 25 MB/s. A USB import stops 30 s after the app leaves the foreground (MSC tested). | *Wired import is viable* |
| Byte-range resume on USB | **Go.** GetPartialObject in MTP, cable pulled at 47 %, resumed after the replug, SHA-256 match. MSC (`requestReadData` at an offset) is untested. | *Byte-range resume on USB* |
| Wireless browsing in 1.0 | **Go.** On the camera's own network, PC Remote lists 391–419 files in 4.7–5.0 s and downloads ARW at 11.7–15.5 MB/s against the 8 MB/s criterion. On the home network: 549 objects in 7.7 s and 10.2 MB/s. Both need Sony's whole-card contents transfer; a plain session lists nothing. | *Wireless browsing in 1.0* |
| SSDP discovery | **The camera announces and the phone hears it without the multicast entitlement**, on its own network (0.73 s) and on the home network (1.9 s and 4.65 s). It doesn't answer a unicast M-SEARCH. The plan's literal criterion (entitlement granted) can't be shown unless Apple has granted it; the request's status isn't recorded. | *SSDP discovery* |
| Transfer-while-shooting | **Go over Wi-Fi.** Sony's ObjectAdded (0xC201) arrives in PC Remote on both networks. Not in MTP over USB. | *Transfer-while-shooting feasible later* |
| Proximity reminder in 1.0 | **Go.** The camera advertises service UUID 1800 on, asleep and off; a background scan woke the locked phone from the next room in 11.76 s and the reminder posted 0.02 s later. A real arrival is untried. | *Proximity reminder in 1.0* |

**What the spike learnt that changes 1.0's design** (detail in section 5):
- A USB import longer than about 30 s needs the app in front; over Wi-Fi a continued task kept a 360-file copy (15.25 GB) going for up to 983 s in the background and under lock.
- The camera sometimes drops its card and Wi-Fi; the copy recovered itself from a restart in 97 s, with the app in front.
- Bluetooth switches the camera's Wi-Fi on in 0.8–2.5 s and hands over the network details; an unused Wi-Fi goes off after about 50 s.
- Handles are stable across sessions, so only the first import lists everything (5.9–8.3 s at 555 handles).
- Photos needs read/write access, but *Limited Access* with nothing selected is enough.

## 2. Still to run on build 14.1

No new build is planned. Every run below exists on 14.1 (checked in `Spike/Sources/Guided/GuidedScripts.swift`). Times are the guided runs' own estimates. "Go/no-go record" means the 13 Nov record should show it; "1.0 design" means it settles a decision in section 5; "Optional" means skipping it costs a blank cell or a provisional decision.

**A. USB: one session, camera on the cable (about 30 min)**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Camera and Photos checks* | Does Photos › Import show a JPG? It is the plan's day-1 pass criterion and has no result; Shamil shoots RAW only, so shoot one JPG first. (Whether the USB mode can be fixed is answered: yes.) | 3 min | Go/no-go record |
| *MSC: resume after a cable pull* | Does `requestReadData` at an offset resume in MSC, and does the file keep its identity after a replug? Decision 7 rests on it. | 3 min | 1.0 design |
| *Copy all RAW to Files*, USB-C, camera in **MTP**; switch to another app once it is copying | Does ImageCaptureCore suspend 30 s after the app leaves the foreground in MTP as it does in MSC? Only MSC is tested. The camera asks for the mode on every plug unless it is fixed, so users will arrive in either. The 65 s catalogue comes first. | 5–12 min; the answer is in once the log shows *did suspend* | 1.0 design |
| *PC Remote: DeviceInfo and ObjectAdded*, then on the Wired tab *Open session*, *Long serial download*, and switch apps | Does a USB session in PC Remote open and import, and does the shutter send ObjectAdded over USB? Does it suspend after 30 s too? | 5 min, plus a few | Optional: transfer-while-shooting is already Go over Wi-Fi |
| *USB: thumbnail speed-ups* | Thumbnails with 1, 2 and 4 in flight; previews from file headers. Sets the Browse pipeline (USB thumbnails take 145–188 ms against the 50 ms target). | 5 min | Optional |

**B. The camera on the home network** (camera: PC Remote Function on, *PC Remote Cnct Method* = *Wi-Fi Access Point*). Do these after Shamil has answered the first three questions in section 3.

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Wi-Fi: one camera mode* › *PC Remote (home Wi-Fi)* | Does the first handshake still take 40 s, or is it quick now? Fills the router and band rows. | 15 min | Optional (1.0 design if the home route is kept) |
| *Copy all RAW to Files* › Wi-Fi › home network | A whole card over the home network. The 03:30 attempt was refused, so the only figure is 20 ARW at 10.2 MB/s. | 10–35 min | Optional |
| *Wi-Fi: GUID after a power cycle*, *Wi-Fi: resume after Wi-Fi off* and *Wi-Fi: lock during a transfer*, on the home network | Does the camera accept the phone again after a restart with no wait? The home-network cells for partial reads, resume and lock are blank. | 5, 5–8 and 8 min | Optional |

**C. The camera's own network (the 1.0 route)**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Copy all RAW to Files* › Wi-Fi, camera's own network, Bluetooth recovery allowed, phone **locked** while the camera is switched off and on | Does recovery work with the phone locked or the app in the background? The 4 Nov recovery ran with the app in front, and its join is made only in the foreground. | about 20 min (the 01:08 run took 20.1) | 1.0 design |
| *Bluetooth: how long an unused Wi-Fi stays up* | Does a second CC08 write restart the 50 s count? What happens with Bluetooth off (that phase didn't run)? | about 6 min | Optional |

**D. Proximity reminder**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Bluetooth: proximity reminder* | The same-room case with the scan started after the lock, which the 2 Nov result (build 6) couldn't show, then the next room. | 10 min | Go/no-go record |
| A real arrival, by hand (no guided run): Bluetooth tab › *Watch in background*, camera away long enough for iOS to forget it (for example in the car), phone locked, camera brought into range. Then the *Creators' App connected*, *quit* and *Kill app to test relaunch* rows. | Does iOS report the camera afresh on arrival, and does a relaunch after a kill work? | 10 min plus the time away | Go/no-go record |

**E. Photos *Don't Allow*, last, on a fresh install** (Photos tab, runbook steps A1–A4). Deleting the app deletes the log, the fixtures and the default copy folder, and gives the Wi-Fi tab a new GUID. Before it: *Export JSON*, *Copy measurements table*, *Share fixtures (zip)* and save them off the phone. About 10 min. Needed for: 1.0 design (the Photos permission flow).

**Not a run: a Bluetooth trace of Creators' App leaving.** Apple's Bluetooth logging profile on the phone and PacketLogger on the Mac, to find the write that switches the camera's Wi-Fi off about 1 s after Creators' App leaves. It decides decision 2 below. It needs the Mac and an evening; optional, but without it decision 2 is made on the measured behaviour alone.

**Suggested order** (Shamil's call): tonight A; Thu 5 Nov the Mac (section 4, fixtures, and the trace if wanted); Fri 6 Nov C, and B once the three home-network questions are answered; the weekend or Mon 9 Nov D; Tue 10 Nov E, last. Wed 11 – Fri 13 Nov for paperwork and the decision. Skip any optional row that runs late: its cell becomes "not run" in the findings.

## 3. Questions waiting on Shamil

**The home network (4 Nov, 03:23–03:41)**
- What did you change on the camera between 03:33 and 03:38 to make PC Remote accept the connection (*Pairing*? an access-authentication setting?)
- What did the camera show during the 40 s first handshake?
- Router (access point) model and band. The measurements table's column is headed "UniFi LAN"; if it isn't a UniFi, rename it.

**Lock and background runs**
- Did you tap Stop in the Live Activity during the USB lock run at 03:09? The log can't tell Stop from an expiry.
- What was in front during the background spells of the 01:57 USB copy?
- What was open during the 424 s and 139 s in the background after the Continue in the 23:51 Wi-Fi copy?

**Setup rows:** card type, and the cable.

**Earlier items marked "to confirm" in the findings**
- Was the 3 Nov 00:20 run really with PC Remote Function off?
- Is "PC Remote over Wi-Fi Direct" the right name for the camera's own network? (The mode matrix says "method to confirm".)
- The multicast request: was it submitted, when, and under what reference?

**Choices for you**
- Do you want the Bluetooth trace (section 2)?
- Decisions 1–9 in section 5.

## 4. Paperwork before 13 Nov

**Fixtures (needs the Mac).** `Fixtures/a7c2/` is empty in the repo.
1. On the phone: Log › Fixtures › *Share fixtures (zip)*.
2. On the Mac: unzip it and `ditto` the `a7c2` folder over `Fixtures/a7c2/`.
3. `make fixtures`, then `make test`. A failure means the codec disagrees with the camera: fix `PTPKit`, never the fixture.
4. Check that nothing under `Fixtures/` holds a Wi-Fi password, a QR payload, a `.pcap` or an `objectproplist*.bin`, and that the serial and the hardware ID in the SSDP description are zeroed (`scripts/redact-fixtures.py` and the pre-commit hook do this; confirm).
5. Commit on a branch.

**Findings: the blank rows**
- *Setup:* card (type, files by kind), cable, home LAN (band, router model). The camera's band is 5 GHz only; its channel isn't known.
- *Menu wording:* twelve rows are empty: `Version`, `USB LUN Setting`, `USB Power Supply`, `Wi-Fi Connect`, `Access Point Set.`, `Wi-Fi Frequency Band`, `Smartphone Connect`, `PC Remote Function`, the two *PC Remote Cnct Method* values, *Pairing* and `Select on Camera & Send` (mark that one "not used: dropped 3 Nov"). The *Select on Connect* setting's own name is also unrecorded. Read them off the camera: the app's empty-state copy will use these words.
- *Open questions:* the USB 2 throughput row is blank (the numbers are in *Wired import is viable*; add the card type).
- *ImageCaptureCore facts:* two blank rows (`deviceDidBecomeReady` on a reopen; `ICCameraDevice.batteryLevel` against PTP BatteryLevel). Run or mark skipped.
- *Measurements:* paste *Copy measurements table* over the table; mark each dropped cell "skipped (stills-only 1.0)" or "skipped (not a 1.0 decision)" rather than leaving it blank. Mark the QR-code row "not seen": PC Remote and Smartphone Connect showed no QR code (2 Nov), and the details come over Bluetooth.

**Multicast entitlement: submit or skip.**
- The findings now say passive listening works: NOTIFYs arrived without the key in a TestFlight build, on both networks. Our own M-SEARCH never went out, and the camera ignores a unicast one, so whether it answers a multicast search is unknown and, for 1.0, unneeded.
- The home-network announcement took 4.65 s once, inside the proposal's 5 s discovery target but only just. A typed address is the fallback.
- Options: record SSDP as Go on passive listening and skip the request; or submit anyway (the plan says turnaround is days to weeks) to keep active search open. Either way fill the findings' entitlement section, and reword the proposal's "must be approved before the first TestFlight external build".

**Go/no-go decision record** (findings, last section): date, decider, wireless scope, and the six result rows with the numbers in section 1.

**Proposal updates** the plan asks for, and what the findings now contradict:
- *Transport table:* Bluetooth is "proximity only, no GATT traffic" for 1.0; the 1.0 route now reads and writes Sony's characteristics (decision 6).
- *Why we do not use Sony's own protocols:* Wi-Fi listing, resume and ObjectAdded all use Sony's operations (decision 6).
- *Performance budget:* "camera visible ≤ 5 s on Wi-Fi" against 13.8–18.8 s from Start to the camera answering (join prompt included); measured thumbnails, listing and throughput; USB 3 stays unmeasured.
- *Background strategy:* "the USB session survives suspension" is true, but nothing transfers after 30 s.
- *Permissions:* `.addOnly` becomes read/write with Limited Access allowed.
- *Iteration 2:* "re-plugging after a pull resumes within 2 s" can't be met, because nothing answers until the catalogue is done (about 65 s in MTP, 7–12 s in MSC). *Iteration 4:* "lock the phone during a 2 GB import and it finishes" is about 50 s at 40 MB/s, so it fails over USB as written.
- *Risks and open questions:* tick the four open questions that now have answers; retire the first two risks.

**Iteration 1 backlog:** it is wired-only and still marked a draft. Finalise it on 13 Nov from the findings (section 6).

## 5. Design decisions for 1.0

Each is Shamil's. The recommendation is mine, drawn from the findings; "provisional" means a run or an answer in sections 2 and 3 could change it.

**1. USB: the 30 s foreground limit.**
- *Evidence:* in MSC, ImageCaptureCore reports *will suspend* when the app leaves the foreground and *did suspend* 30.0–30.1 s later, in the background (four times of four) and under lock (03:07; nothing moved for the remaining 629 s). A continued task doesn't change it. The session survives, and *resumed operations* comes 0.3–0.9 s after the app returns. A full card of 360 ARW takes about 6½ minutes at 40 MB/s. MTP and PC Remote are untested.
- *Recommendation:* the import asks to stay in front and keeps the screen on; the engine pauses on *did suspend* and continues when the app returns. A continued task over USB buys at most 30 s, so it isn't a requirement for wired.
- *Provisional on:* the MTP run.

**2. Wi-Fi: leave the camera's network after an import, or stay joined.**
- *Evidence:* removing the hotspot configuration 46 s after CloseSession made the camera's Wi-Fi start switching off 51.2 s later and be off at 53.2 s, with no write. Removing it brings the iOS join prompt back; re-applying a saved configuration (the 01:12 recovery) didn't prompt. If the phone stays joined, the camera's Wi-Fi stays up (status 2 for 45 s after CloseSession; a longer stay is untested). Creators' App's Wi-Fi goes off about 1 s after it leaves; how isn't known. The camera's battery cost of a Wi-Fi left on isn't measured.
- *Options:* (a) leave after each import: a join prompt every time, the camera saves its battery; (b) keep the configuration: no prompt, camera Wi-Fi stays up while the phone is joined; (c) (b) plus the write, if the trace finds it.
- *Recommendation (provisional):* (a), because it is measured and costs the camera nothing; revisit if the trace finds the write.

**3. Wi-Fi: join promptly, and recover.**
- *Evidence:* the camera gives about 50 s from status 2; the joins took 7.4–10.6 s with the prompt. In the 4 Nov recovery, two fixed 30 s waits made up 62 of 97 s. The second was waiting for iOS to rejoin; the first was waiting for the port. Only the join is known to need the foreground.
- *Recommendation:* join as soon as CC09 reports status 2; watch CC09 during the join prompt and, if it reaches 3 or 0, write CC08 = 0x01 again and retry. Go to Bluetooth when the port stops answering, but don't switch on a camera the person has just switched off. Say in the UI that recovery needs the app in front unless the locked run shows otherwise.
- *Provisional on:* the locked-recovery run.

**4. Pause, continue and stalled files.**
- *Evidence:* both continued-task expiries so far came as the Camera app was opened. *Continue* started a new task in 0.03 s and copied again 11 s after the tap, 8.3 s of it a relist that stable handles make unnecessary; the file in flight restarted from its start. Over USB the same `requestDownload` survived a 632 s suspension, yet the spike's 60 s limit failed three downloads. Over Wi-Fi a drop made the copy count 82 files as failed before the link closed.
- *Recommendation:* treat expiry as normal: pause, notify, and on Continue start a new task, reopen, ask for new handles only, and resume at the file in flight. Report progress in bytes. A stall pauses and retries; "failed" is for real errors, with a limited number of retries.

**5. The home network as a second route.**
- *Evidence:* works after the camera has accepted the phone once; no join prompt and the phone keeps its internet; the app can find the camera by listening for its announcements. Slower so far: 10.2 against 15.5 MB/s, thumbnails 48 against 35–39 ms. It needs a camera setting (*Wi-Fi Access Point*), and the 40 s first handshake is unexplained. Whether the Bluetooth switch-on works with the camera on the home network is untested.
- *Recommendation (provisional):* the camera's own network over Bluetooth stays the 1.0 route; the home network is supported when the camera is already on it, after Iteration 3's core. Decide after Shamil's answers (section 3) and group B.

**6. Sony-specific operations and the Bluetooth hand-off.**
- *Evidence:* a plain PTP/IP session gets StoreNotAvailable; listing needs SDIO_OpenSession (0x9210), Sony's init sequence and 0x9212, and resume needs 0x9211. The Bluetooth hand-off comes from reverse-engineered notes and has worked on this body. The proposal says 1.0 uses neither. Without the hand-off the person switches on PC Remote Function and joins in Settings, as on 2 Nov. Firmware 2.00 and 2.01 have both been seen.
- *Recommendation:* accept both. Read the operation list from DeviceInfo before using any Sony operation (as build 9.1 does), keep Sony-specific code in one place, keep fixtures per firmware, and move the Bluetooth hand-off from 1.1 into Iteration 3. Your 3 Nov decision already treats the Bluetooth switch-on as the smartphone connection.

**7. Wired mode, identity and resume.**
- *Evidence:* MSC lists 9 × faster and runs JPG 60 % faster; MTP has stable object identifiers and GetPartialObject. In MSC the PTP flag is misleading. A 40 MB ARW restarts in about 1 s over USB.
- *Recommendation:* support both and recommend MSC in the app's copy; branch on transport type, not `acceptsPTPCommands`; one import path (`requestDownloadFile`, with `requestReadData` at an offset for resume). Identity: `PersistentUniqueObjectIdentifier` in MTP; folder, name, capture date and size in MSC. Byte resume is low priority for wired stills and matters for Wi-Fi (0x9211). Show the last-known card at once while ImageCaptureCore lists.
- *Provisional on:* the MSC resume run.

**8. Proximity reminder requirements.** Record these in the proposal and the Iteration 4 backlog; they need no decision beyond the wording ("nearby", not "switched on"). Confirm the camera after a wake by the stored peripheral identifier or Sony's company ID, because 1800 is a generic service. The trigger is coming into range: the advertisement is identical on, asleep and off. Restart the scan from a wake, not a timer; hold reminders while connected or importing; ask for notification permission when the person switches the reminder on.

**9. Photos access.** Ask for read/write and accept Limited Access with nothing selected; stage files as complete-until-first-unlock; find the album by its stored identifier. If *Don't Allow* isn't run, assume it means "import to Files only" and say so in the UI.

## 6. After the go/no-go

1. Fri 13 Nov: fill the decision record in the findings and update the proposal (section 4).
2. Create the production workspace, as in the backlog's section 0. `PTPKit` moves in unchanged; nothing from `Spike/` is carried in. Until the decision, the workspace stays unstarted.
3. Iteration 1 starts Mon 16 Nov (weeks 3–6, Shamil alone). Its backlog covers wired import only, but wireless is in 1.0, so on 13 Nov:
   - finalise the wired items from the findings (MSC alongside MTP, pause on *did suspend*, no resume-within-2 s criterion);
   - add Iteration 3 and 4 sections or files: the Wi-Fi link (Sony's whole-card session, 0x9211 resume, passive SSDP, typed address), the Bluetooth hand-off and join flow, recovery, pause and continue with notifications, the continued task and Live Activity for Wi-Fi, the proximity reminder, and the home network if decision 5 keeps it. The second engineer starts 18 Jan and needs these in the onboarding pack;
   - keep the open point in backlog section 7: Iteration 1 has no wireless link, so the engine needs a test-only way to reach `PTPSimulator`.
4. Make the engine transport-neutral from Iteration 1 (pause, continue, stall and retry), because those rules apply to both links.

## 7. Dropped or deferred

**Dropped (kept from earlier):**
- All MP4 rows, the 1 GB clips and the 4 GiB / 0x95C1 question (1.0 is stills only).
- A 2,000-file card in MTP and the 300-frame *Scaling* burst (projected: see the findings).
- More MTP listing experiments (GetObjectPropList variants, PTP listing): the camera sets the pace.
- Instruments Allocations and the Energy gauge (70 MB against the 150 MB budget).
- Mac gphoto2 and Image Capture probes, and the Mac day-6 probes as a required step: the phone did the same work.
- Battery per GB on every link.
- BLE: all nine power × pairing combinations.
- The Photos Import RAW-only mystery (not our app's path).
- *Smartphone Connect*, *Send to Smartphone* and the RAW+JPEG pairing test (3 Nov).
- Wi-Fi two in flight (one transaction per PTP/IP session).

**Now unnecessary:**
- The Sony SDIO experiment: the whole-card session uses it.
- Active SSDP search and the QR-code scan for the 1.0 route.
- Repeating every Wi-Fi test on the home network: group B is optional.

**Changed:** the second MTP lifecycle run was dropped on 2 Nov; it returns as one row in group A, because users will land in either USB mode.

**Out of scope for 1.0, as in the proposal:** video, transfer-while-shooting, Bluetooth wake beyond the Wi-Fi switch-on, USB 3.
