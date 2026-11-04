# Rest of the spike: what remains before the product build (from 4 Nov)

Written Wednesday 4 Nov 2026 on spike build 14 (TestFlight 0.1 (14.1)). It rests on `docs/spike-findings.md`, including the home-network runs of 4 Nov 03:23–03:41 (PR #52), `docs/spike-plan.md`, `docs/spike-runbook.md` and `docs/proposal.md`. It proposes; the decisions stay with Shamil and the 13 Nov go/no-go.

## Decisions (Shamil, 2 Nov)

- **Wireless is in 1.0.** The wireless go/no-go is no longer whether to ship it but which path works and how well. PTP/IP browsing on the camera's access point is the first choice; if no camera mode lists the card, the camera's *Send to Smartphone* is the path. Iteration 3 is in 1.0 either way, so both need testing: every camera Wi-Fi mode, the join and pairing flow, resume after a drop, behaviour under lock, and the fallback.
- **Battery per GB and MP4 are out of the spike.** 1.0 imports stills; nothing in it depends on battery use per GB.
- **Scaling is measured, not assumed:** the guided *Scaling* run lists the card cold in MSC (and MTP), adds a burst of about 300 frames, lists again, and projects 2,000 and 5,000 files from the two sizes. (The burst was dropped on 3 Nov; see below.)
- **More of the testing runs as guided runs** in the spike's *Guided* tab (build 8), so each evening needs fewer builds and less reading of the runbook.

## Decisions (Shamil, 3 Nov)

- **Dropped:** *Smartphone Connect* (the Bluetooth switch-on is that connection), *Send to Smartphone* (the fallback isn't needed: the camera lists its card over PTP/IP), the RAW+JPEG / RAW+HEIF pairing test (Shamil shoots RAW only; the pairing rule stays the default: same folder, same stem, capture time within 1 s), and the 300-frame *Scaling* burst (projected from the listings already made; see *Wireless browsing in 1.0* in the findings).
- **Still to run (as of 3 Nov):** PC Remote over the home Wi-Fi, resume in MSC, PC Remote over USB, a real proximity arrival, *Copy all RAW to Files* over USB-C, the build 14 Bluetooth and copy runs, and Photos *Don't Allow* (last, on a fresh install). On 3–4 Nov the build 14 runs, the USB-C copy and the home-network runs were done (the idle run's Bluetooth-off phase didn't run, because the Wi-Fi was already off). What is left of this list, and what has come up since, is in section 2.

---

## 1. Where the spike stands

Every go/no-go row of the plan has an answer. Nothing below is waiting on a run to reach a decision on 13 Nov; the open runs settle details of 1.0 and complete the record.

| Question | Answer on 4 Nov | Findings section |
| --- | --- | --- |
| Wired import is viable | **Go.** MSC lists 391 files in 7.2 s (547 in 11.6 s) and downloads ARW at 39.9–41.7 MB/s. MTP downloads at 38–39 MB/s but takes 65 s to list, and JPG runs at 25.6 MB/s against 41.7 in MSC. The goal is ≥ 25 MB/s. A USB import stops 30 s after the app leaves the foreground (MSC and MTP tested). | *Wired import is viable* |
| Byte-range resume on USB | **Go.** GetPartialObject in MTP, cable pulled at 47 %, resumed after the replug, SHA-256 match. MSC (`requestReadData` at an offset) is untested. | *Byte-range resume on USB* |
| Wireless browsing in 1.0 | **Go.** On the camera's own network, PC Remote lists 391–419 files in 4.7–5.0 s and downloads ARW at 11.7–15.5 MB/s against the 8 MB/s criterion. On the home network, after the camera's access authentication was turned off: 549 objects in 7.7 s and 10.2 MB/s (one run, app in front). Both need Sony's whole-card contents transfer; a plain session lists nothing. | *Wireless browsing in 1.0* |
| SSDP discovery | **The camera announces and the phone hears it without the multicast entitlement**, on its own network (0.73 s) and on the home network (1.9 s and 4.65 s into a 5 s listen). How often it announces isn't measured. It doesn't answer a unicast M-SEARCH. The plan's literal criterion (entitlement granted) can't be shown unless Apple has granted it; the request's status isn't recorded. | *SSDP discovery* |
| Transfer-while-shooting | **Go over Wi-Fi.** Sony's ObjectAdded (0xC201) arrives in PC Remote on both networks. Not in MTP over USB. | *Transfer-while-shooting feasible later* |
| Proximity reminder in 1.0 | **Go.** The camera advertises service UUID 1800 on, asleep and off; a background scan woke the locked phone from the next room in 11.76 s and the reminder posted 0.02 s later. A real arrival is untried. | *Proximity reminder in 1.0* |

**What the spike learnt that changes 1.0's design** (detail in section 5):
- A USB import longer than about 30 s needs the app in front; over Wi-Fi a continued task kept a 360-file copy (15.25 GB) going for nearly 13 minutes in the background, 329 s of it locked; the task ran 983 s in all without expiring.
- The camera sometimes drops its card and Wi-Fi; the copy recovered itself from a restart in 97 s, with the app in front.
- Bluetooth switches the camera's Wi-Fi on in 0.8–2.5 s and hands over the network details; an unused Wi-Fi goes off after about 50 s.
- Handles are stable across sessions, so only the first import lists everything (5.9–8.3 s at 555 handles).
- Photos needs read/write access, but *Limited Access* with nothing selected is enough.

## 2. Still to run on build 14.1

No new build is planned. Every run below exists on 14.1 (checked in `Spike/Sources/Guided/GuidedScripts.swift`). Times are the guided runs' own estimates. "Plan record" means it fills a findings cell the plan asks for and is not needed for the decision; "1.0 design" means it settles a decision in section 5; "Optional" means skipping it costs a blank cell or a provisional decision.

**A. USB: one session, camera on the cable (about 15–20 min)**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Camera and Photos checks* | Does Photos › Import show the card's JPGs (187 are on it)? It is the plan's day-1 pass criterion and has no result. (Whether the USB mode can be fixed is answered: yes.) | 3 min | Plan record (optional) |
| *MSC: resume after a cable pull* | Does `requestReadData` at an offset resume in MSC, and does the file keep its identity after a replug? Decision 7 rests on it. | 3 min | 1.0 design |
| *PC Remote: DeviceInfo and ObjectAdded* (it opens the session itself and waits for the catalogue) | Does ImageCaptureCore list the card in *Remote Shoot (PC Remote)* (`usb.catalog.count`, or the 300 s catalogue limit)? Note what the camera shows on connection (on 4 Nov it went to *Img Dest*). Does the shutter send ObjectAdded over USB? | 5 min | 1.0 design (decision 1: what the app says in PC Remote); the ObjectAdded part is optional |
| *USB: thumbnail speed-ups* | Thumbnails with 1, 2 and 4 in flight; previews from file headers. Sets the Browse pipeline (USB thumbnails take 145–188 ms against the 50 ms target). | 5 min | Optional |

Done on 4 Nov (11:30): the copy in MTP, with the app sent to the background. ImageCaptureCore suspends 30 s after the app leaves the foreground, as in MSC, and iOS ended the continued task each time (Stop ruled out). No copy ran in *Remote Shoot (PC Remote)*: the camera went to a settings page (*Img Dest*) (Shamil). The copy run doesn't refuse that mode, so whether ImageCaptureCore lists the card there is still open; the *PC Remote: DeviceInfo and ObjectAdded* run above answers it.

**B. The camera on the home network** (camera joined to the home Wi-Fi, PC Remote Function on, *PC Remote Cnct Method* = *Wi-Fi Access Point*, access authentication off; what that setting costs in security is a question in section 3).

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Wi-Fi: one camera mode* › *PC Remote (home Wi-Fi)* | Does the first handshake still take 40 s, or is it quick now (the 4 Nov run took 40.2 s, then 6 ms)? | 15 min | Optional (1.0 design if the home route is kept) |
| *Copy all RAW to Files* › *Wi-Fi* › *Home LAN* | A whole card over the home network. The 03:30 attempt was refused (access authentication was on then), so the only figure is 20 ARW at 10.2 MB/s. | 10–35 min | Optional |
| *Wi-Fi: GUID after a power cycle*, *Wi-Fi: resume after Wi-Fi off* and *Wi-Fi: lock during a transfer*, on the home network | Does the camera accept the phone again after a restart with no wait, and does that first connection take 40 s again (its handshake time is logged)? The home-network cells for partial reads, resume and lock are blank. | 5, 5–8 and 8 min | Optional |

**C. The camera's own network (the 1.0 route)**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Copy all RAW to Files* › Wi-Fi, camera's own network, Bluetooth recovery allowed, phone **locked** while the camera is switched off and on | Does recovery work with the phone locked or the app in the background? The 4 Nov recovery ran with the app in front, and its join is made only in the foreground. | about 20 min (the 01:08 run took 20.1) | 1.0 design |
| By hand, stay-joined test (not *Bluetooth: switch Wi-Fi on, join and import*, which removes its configuration 46 s after the session): on the Bluetooth tab tap *Read details and join*, then confirm *Write 0x01 to CC08, then join*. The camera shows no password after a Bluetooth switch-on, and this join keeps its configuration, as option (b) would. On the Wi-Fi tab open a session (*Contents transfer: whole card*), then tap *Disconnect*. Stay joined, with the app in front and the screen on: on 2 Nov iOS moved the phone to the home Wi-Fi when the app went to the background. After 2, 5 and 10 minutes tap *Safe reads* on the Bluetooth tab, note the Wi-Fi status (CC09), and check the phone is still on the camera's network. Don't download in between: a new session restarts the count. | Does the camera's Wi-Fi stay up for a phone that stays joined, past about 100 s after CloseSession? Option (b) of decision 2 rests on it, and the guided run watches only 45 s. | about 15 min | 1.0 design |
| *Bluetooth: switch Wi-Fi on, join and import*, after removing the pairing in Creators' App, in Settings › Bluetooth and in the camera's Bluetooth settings, as the advertisement run's *Not paired* step does (Shamil's call; Creators' App will need pairing again afterwards). If the camera keeps its half of the bond, the result isn't a first-time user's. | Can our app connect, subscribe, write CC08 and read CC06/CC07 without Creators' App's bond, with its own pairing or none? Every hand-off so far had that bond on the phone. Watch `ble.auto.pairingPrompt` and what the camera shows. The run doesn't record that the bond was removed, and its last question (`ble.auto.creatorsAppStillWorks`) will say no for that reason: note both by hand. | about 14 min plus re-pairing | 1.0 design (decision 6, onboarding) |

**D. Proximity reminder**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Bluetooth: proximity reminder* | The same-room case with the scan started after the lock, which the 2 Nov result (build 8, TestFlight 0.1 (6.1)) couldn't show, then the next room. | 10 min | Optional (the "No" is the procedure, not the platform) |
| A real arrival, by hand (no guided run): Bluetooth tab › *Watch in background*, camera away long enough for iOS to forget it (for example in the car), phone locked, camera brought into range. Then the *Creators' App connected*, *quit* and *Kill app to test relaunch* rows. | Does iOS report the camera afresh on arrival, and does a relaunch after a kill work? | 10 min plus the time away | 1.0 design (the reminder's main case; decision 8) |

**E. Photos *Don't Allow*, last, on a fresh install** (Background › *Photos albums, no camera*, runbook steps A1–A4). Deleting the app deletes the log, the fixtures and the default copy folder (move out any copies worth keeping), gives the Wi-Fi tab a new GUID and clears the Bluetooth proximity filter (retype it). Before it: *Export JSON*, *Copy measurements table*, *Share fixtures (zip)* and save them off the phone. About 10 min. Needed for: 1.0 design (the Photos permission flow).

**Not a run: a Bluetooth trace of Creators' App leaving.** Apple's Bluetooth logging profile on the phone and PacketLogger on the Mac, to find the write that switches the camera's Wi-Fi off about 1 s after Creators' App leaves. It decides decision 2 below. It needs the Mac and an evening; optional, but without it decision 2 is made on the measured behaviour alone.

**No guided run on 14.1 answers these; record as open unless done by hand.**
- A second CC08 write while the status is 2, a write during status 3, and an unused Wi-Fi with Bluetooth off. The idle run writes CC08 once, and its Bluetooth-off phase runs only if the Wi-Fi outlives the 3-minute watch, which it doesn't (off at about 51 s). The first and last can be done by hand on the Bluetooth tab. For the second write, tap *Switch camera Wi-Fi on…* again about 30 s after status 2 and watch when the status goes to 3. For Bluetooth off, switch the Wi-Fi on, tap *Disconnect*, wait 60 s, then *Connect + discover* and *Safe reads*. A write during status 3 (1.4–4.5 s long) can't be timed by hand and needs a new build.
- How often the camera announces on the home network: the runs listen for 5 s.
- Why the first Bluetooth connect takes 5–6 s (0.4 s otherwise) matters for time-to-camera; the camera seems slow to take the first connection after it has been idle.
- Whether the Wi-Fi recovery would rejoin with no other known network in range.

**Suggested order** (Shamil's call): tonight A; Thu 5 Nov the Mac (section 4, fixtures, and the trace if wanted); Fri 6 Nov C, and B; the weekend or Mon 9 Nov D; Tue 10 Nov E, last. Wed 11 – Fri 13 Nov for paperwork and the decision. Skip any optional row that runs late: its cell becomes "not run" in the findings.

## 3. Questions waiting on Shamil

**The home network (4 Nov, 03:23–03:41)**
- Access point model and band. The network is UniFi behind an older UniFi Security Gateway, so the measurements table's "UniFi LAN" column name stands.
- What turning access authentication off costs in security, and its exact menu name and path. Check before 1.0 asks anyone to do it.

**Lock and background runs**
- Was Stop tapped in the Live Activity during the USB lock run (03:07; the task ended at about 03:09, with the phone locked)? The log can't tell Stop from an expiry.
- What was in front during the background spells of the 01:57 USB copy, including its two expiries?
- What was open during the 424 s and 139 s in the background after the Continue in the 23:51 Wi-Fi copy?

**Setup rows:** card type, and the cable.

**Earlier items marked "to confirm" in the findings**
- Was the 3 Nov 00:20 run really with PC Remote Function off?
- Is "PC Remote over Wi-Fi Direct" the right name for the camera's own network? (The mode matrix says "method to confirm".)
- The multicast request: was it submitted, when, and under what reference?
- What does the camera show on the first connection from the iPhone? (Not recorded.)
- Was *Remote Power ON/OFF* on during the 2 Nov advertisement scans? (The advertisement section says not recorded; the menu table says On.)

**Choices for Shamil**
- Is the Bluetooth trace wanted (section 2)?
- Is the Bluetooth hand-off to be tested without Creators' App's bond (section 2 C)? If not, decision 6 stays provisional on it.
- Do the proposed drops in section 7 stand?
- Decisions 1–9 in section 5.

## 4. Paperwork before 13 Nov

**Fixtures (needs the Mac).** `Fixtures/a7c2/` is empty in the repo.
1. On the phone: Log › Fixtures › *Share fixtures (zip)*.
2. On the Mac: unzip it and `ditto` the `a7c2` folder over `Fixtures/a7c2/`.
3. Delete any `objectproplist*.bin` from `Fixtures/a7c2/usb/` first: `make fixtures` copies every `.bin` into the PTPKit test bundle, and the hook refuses one anywhere. Then `make fixtures`, then `make test`. A failure means the codec disagrees with the camera: fix `PTPKit`, never the fixture.
4. `scripts/redact-fixtures.py` (run by `make fixtures`) zeroes the serial in `deviceinfo.bin`, and the serial and the hardware ID in `ssdp-description.xml`. The pre-commit hook refuses a staged file that still has either, and any staged `.pcap` or `objectproplist*.bin`. Nothing checks for a Wi-Fi password or a QR payload (the app never writes them), or for these three, so check them by eye:
   - the `ble/advert-*.json` snapshots are kept out of the commit, or have their `identifier` and `manufacturerDataHex`/`manufacturerDataVariants` removed (they hold the Bluetooth peripheral identifier and data that may identify the camera);
   - `ptpip/ssdp-description.xml` doesn't carry the camera's home-network address (it was saved again on the home network on 4 Nov). If it does, save it again on the camera's own network before the export: with the phone on that network, tap Wi-Fi tab › *SSDP M-SEARCH multicast* (the camera doesn't answer the unicast search). Group B saves it from the home network again, so check it in any later export too;
   - `ptpip/sdio-extdeviceinfo.bin`, Sony's private dataset, has been looked at.
5. Commit on a branch.

**Findings: the blank rows**
- *Setup:* card (type, files by kind), cable, home LAN (access point model and band; the network is UniFi behind a UniFi Security Gateway). The camera's band is 5 GHz only; its channel isn't known.
- *Menu wording:* twelve rows are empty: `Version`, `USB LUN Setting`, `USB Power Supply`, `Wi-Fi Connect`, `Access Point Set.`, `Wi-Fi Frequency Band`, `Smartphone Connect`, `PC Remote Function`, the two *PC Remote Cnct Method* values, *Pairing* and `Select on Camera & Send` (mark that one "not used: dropped 3 Nov"). The names of the *Select on Connect* setting and of access authentication (with its path) are also unrecorded. `Version` also settles the firmware question in decision 6. Read them off the camera: the app's empty-state copy will use these words.
- *Open questions:* the USB 2 throughput row is blank (the numbers are in *Wired import is viable*; add the card type).
- *ImageCaptureCore facts:* two blank rows (`deviceDidBecomeReady` on a reopen; `ICCameraDevice.batteryLevel` against PTP BatteryLevel). Run or mark skipped.
- *Measurements:* paste *Copy measurements table* over the table; mark each dropped cell "skipped (stills-only 1.0)" or "skipped (not a 1.0 decision)" rather than leaving it blank.
- *PTP/IP and join facts:* mark the QR-code row "not seen" (PC Remote and Smartphone Connect showed no QR code on 2 Nov, and the details come over Bluetooth), and update the join-flow row from the Bluetooth join runs (`ptpip.ap.join` 10.6 s), which it still calls not measured.

**Multicast entitlement: submit or skip.**
- Passive listening worked without the key on both networks (TestFlight builds). Our own M-SEARCH never went out, and the camera ignores a unicast one, so whether it answers a multicast search is unknown.
- The announcement interval isn't measured, and 4.65 s was inside a 5 s listen, so the proposal's 5 s target isn't shown. Active search would help if announcements are infrequent. A typed address is the fallback.
- Options: record SSDP as Go on passive listening and skip the request; or submit anyway (the plan says turnaround is days to weeks) to keep active search open. Shamil's choice. Either way fill the findings' entitlement section, and reword the proposal's "must be approved before the first TestFlight external build".

**Go/no-go decision record** (findings, last section): date, decider, wireless scope, and the six result rows with the numbers in section 1.

**Proposal updates** the plan asks for, and what the findings now contradict:
- *Transport table:* Bluetooth is "1.0 for proximity detection (advertisement match only, no GATT traffic)"; the 1.0 route now reads and writes Sony's characteristics (decision 6).
- *Why we do not use Sony's own protocols:* Wi-Fi listing, resume and ObjectAdded all use Sony's operations (decision 6).
- *Performance budget:* "camera visible after connect ≤ 5 s on Wi-Fi": the whole card is ready 2.0–3.0 s after the session opens and listing takes 4.7–8.3 s; joining the camera's network separately takes 13.8–18.8 s from Start. "≤ 2 s wired" isn't met (7–12 s in MSC, 65 s in MTP), nor is goal 1's "card contents within 5 seconds" on USB. Goal 2's "≥ 30 MB/s wired" holds for ARW (38–42 MB/s) and fails for JPG in MTP (25.6 MB/s); USB 3 stays unmeasured. Update the measured thumbnails, listing and throughput.
- *Background strategy:* "the USB session survives suspension" is true, but nothing transfers after 30 s; "the camera keeps the AP up for several minutes" is about 50 s after the phone leaves.
- *Permissions:* `.addOnly` becomes read/write with Limited Access allowed.
- *Iteration 2:* "re-plugging after a pull resumes within 2 s" can't be met, because nothing answers until the catalogue is done (about 65 s in MTP, 7–12 s in MSC). *Iteration 4:* "lock the phone during a 2 GB import and it finishes" is about 50 s at 40 MB/s, so it fails over USB as written.
- *Iteration 3 and roadmap:* the QR scan is replaced by the Bluetooth hand-off if decision 6 is taken, and 1.1's list (Bluetooth wake and credential hand-off) changes with it.
- *Risks and open questions:* tick the USB-mode and GUID open questions now. Tick ObjectAdded over USB once PC Remote over USB has run or is marked not run, and the USB 2 throughput one once the card type is recorded; retire the first two risks and the last (the camera keeps advertising when switched off); add the reverse-engineered Sony pieces, ImageCaptureCore's 30 s suspension and the camera dropping its card with Creators' App open.

**Iteration 1 backlog:** it is wired-only and still marked a draft. Finalise it on 13 Nov from the findings (section 6).

## 5. Design decisions for 1.0

Each is Shamil's. The recommendations are drawn from the findings; "provisional" means a run or an answer in sections 2 and 3 could change it.

**1. USB: the 30 s foreground limit.**
- *Evidence:* in MSC, ImageCaptureCore reports *will suspend* when the app leaves the foreground and *did suspend* 30.0–30.1 s later, in the background (four times of four) and under lock (03:07; nothing moved for the remaining 629 s). A continued task doesn't change it. The session survives, and *resumed operations* comes 0.3–0.9 s after the app returns. A full card of 360 ARW takes about 6½ minutes at 40 MB/s. MTP behaves the same (4 Nov 11:30, three of three). In *Remote Shoot (PC Remote)* no copy ran, and whether ImageCaptureCore lists the card there is still open.
- *Recommendation:* the import asks to stay in front and keeps the screen on; the engine pauses on *did suspend* and continues when the app returns. A continued task over USB buys at most 30 s, so it isn't a requirement for wired. If ImageCaptureCore can't list the card in PC Remote, the app asks for MSC or MTP.
- *Provisional on:* whether ImageCaptureCore lists the card in PC Remote (*PC Remote: DeviceInfo and ObjectAdded*, group A).

**2. Wi-Fi: leave the camera's network after an import, or stay joined.**
- *Evidence:* in one run, removing the hotspot configuration 46 s after CloseSession made the camera's Wi-Fi start switching off 51.2 s later and be off at 53.2 s, with no write. Removing it brings the iOS join prompt back; re-applying a saved configuration (the 01:12 recovery) didn't prompt. If the phone stays joined, the camera's Wi-Fi stays up (status 2 for 45 s after CloseSession; a longer stay is untested, and option (b) rests on it). Creators' App's Wi-Fi goes off about 1 s after it leaves; how isn't known. The camera's battery cost of a Wi-Fi left on isn't measured.
- *Options:* (a) leave after each import: a join prompt every time, the camera saves its battery; (b) keep the configuration: no prompt, camera Wi-Fi stays up while the phone is joined (untested beyond 45 s); (c) (b) plus the write, if the trace finds it.
- *Recommendation (provisional):* (a), because it is measured, once: the camera's Wi-Fi goes off about 53 s after the leave, with no write. Revisit if the trace finds the write or the stay-joined test shows (b) is safe.

**3. Wi-Fi: join promptly, and recover.**
- *Evidence:* the camera gives about 50 s from status 2; the joins took 7.4–10.6 s with the prompt. In the 4 Nov recovery, two fixed 30 s waits made up 62 of 97 s. The second was waiting for iOS to rejoin; the first was waiting for the port. Only the join is known to need the foreground.
- *Recommendation:* join as soon as CC09 reports status 2; watch CC09 during the join prompt and, if it reaches 3 or 0, write CC08 = 0x01 again and retry. Removing the second wait is measured (join as soon as CC09 reports 2). The first wait, before going to Bluetooth, may have to stay: the app can't yet tell a camera that is back on from one the person switched off, and 1.0 shouldn't switch on the latter. Keep a wait, and treat how to tell them apart as open. Say in the UI that recovery needs the app in front unless the locked run shows otherwise.
- *Provisional on:* the locked-recovery run.

**4. Pause, continue and stalled files.**
- *Evidence:* both Wi-Fi expiries came as the Camera app was opened. The three USB expiries came 31–74 s after the progress last moved, during ImageCaptureCore's suspension: two in the 01:57 copy, phone unlocked, with what was in front not recorded, and one in the 03:07 run with the phone locked (Stop in the Live Activity not ruled out). Three more in the 11:30 MTP copy came 34–59 s after the progress stopped, phone unlocked, with Stop ruled out by Shamil; yet in the 01:57 copy three stalls went about 60 s without progress without one (two of them were 109–114 s without a byte, with a failed file moving the progress at 60 s). *Continue* started a new task in 0.03 s and copied again 11 s after the tap, 8.3 s of it a relist that stable handles make unnecessary; the file in flight restarted from its start. Over USB the same `requestDownload` survived a 632 s suspension, yet the spike's 60 s limit failed three downloads. Over Wi-Fi a drop made the copy count 82 files as failed before the link closed.
- *Recommendation:* treat expiry as normal: pause, notify, and on Continue start a new task, reopen, ask for new handles only, and resume at the file in flight. Report progress in bytes. A stall pauses and retries; "failed" is for real errors, with a limited number of retries.

**5. The home network as a second route.**
- *Evidence:* works after a one-time camera setup (home Wi-Fi, PC Remote Cnct Method *Wi-Fi Access Point*, access authentication off); no join prompt (whether the phone keeps its internet wasn't checked); the app can find the camera by listening for its announcements; the first handshake took 40.2 s (the app must wait at least that long). Slower so far: 10.2 against 11.7–15.5 MB/s, thumbnails 48 against 35–39 ms. One run, app in front. Whether the Bluetooth switch-on works with the camera on the home network is untested.
- *Recommendation (provisional):* the camera's own network over Bluetooth stays the 1.0 route; the home network is supported when the camera is already on it, after Iteration 3's core. Decide after group B and the answer on what turning access authentication off costs in security (section 3).

**6. Sony-specific operations and the Bluetooth hand-off.**
- *Evidence:* a plain PTP/IP session gets StoreNotAvailable; listing needs SDIO_OpenSession (0x9210), Sony's init sequence and 0x9212, and resume needs 0x9211. The Bluetooth hand-off comes from reverse-engineered notes and has worked on this body, always with Creators' App's bond on the phone. The proposal says 1.0 uses neither, for two reasons: fragility against firmware updates and App Store review. Both still apply; the DeviceInfo check and per-firmware fixtures address the first, and nothing yet addresses the second. Without the hand-off the person switches on PC Remote Function and joins in Settings, as on 2 Nov. USB DeviceInfo reported "2.0" and PTP/IP and Bluetooth "2.01" on the same body; reading Setup › Version settles it.
- *Recommendation:* accept both. Read the operation list from DeviceInfo before using any Sony operation (as build 9.1 does), keep Sony-specific code in one place, keep fixtures per firmware (as general advice), and move the Bluetooth hand-off from 1.1 into Iteration 3. Shamil's 3 Nov decision already treats the Bluetooth switch-on as the smartphone connection. The trade-off against the two costs above is Shamil's.
- *Provisional on:* the hand-off test without Creators' App's bond (section 2 C), which decides 1.0's onboarding.

**7. Wired mode, identity and resume.**
- *Evidence:* MSC lists 9 × faster and runs JPG 60 % faster; MTP has stable object identifiers and GetPartialObject. In MSC the PTP flag is misleading. A 40 MB ARW restarts in about 1 s over USB.
- *Recommendation:* support both and recommend MSC in the app's copy; branch on transport type, not `acceptsPTPCommands`; one import path (`requestDownloadFile`, with `requestReadData` at an offset for resume). Identity: `PersistentUniqueObjectIdentifier` in MTP (about 385 ms per object, so read it only for new objects; MTP handles were also stable across a replug); folder, name, capture date and size in MSC. Byte resume is low priority for wired stills and matters for Wi-Fi (0x9211). Show the last-known card at once while ImageCaptureCore lists.
- *Provisional on:* the MSC resume run.

**8. Proximity reminder requirements.** Record these in the proposal and the Iteration 4 backlog; they need no decision beyond the wording ("nearby", not "switched on"). Confirm the camera after a wake by the stored peripheral identifier, or by Sony's company ID together with the name, because 1800 is a generic service. The trigger is coming into range: the advertisement is identical on, asleep and off. Restart the scan from a wake, not a timer; hold reminders while connected or importing; ask for notification permission when the person switches the reminder on.

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

**Dropped by Shamil (2 and 3 Nov):**
- All MP4 rows, the 1 GB clips and the 4 GiB / 0x95C1 question (1.0 is stills only), and battery per GB on every link (2 Nov).
- *Smartphone Connect*, *Send to Smartphone*, the RAW+JPEG pairing test and the 300-frame *Scaling* burst (3 Nov; projected: see the findings).

**Proposed drops, not yet confirmed by Shamil** (section 3):
- A 2,000-file card in MTP.
- More MTP listing experiments (GetObjectPropList variants, PTP listing): the camera sets the pace.
- Instruments Allocations and the Energy gauge (the app's own probe peaked at 70 MB over USB and up to 113 MB over Wi-Fi, against the 150 MB budget).
- Mac gphoto2 and Image Capture probes, and the Mac day-6 probes as a required step: the phone did the same work.
- BLE: all nine power × pairing combinations.
- The Photos Import RAW-only mystery (not our app's path).
- Wi-Fi two in flight (one transaction per PTP/IP session).
- The second MTP lifecycle run as a separate run; it came back as the MTP copy in group A, run on 4 Nov 11:30, because users will land in either USB mode.

**Now unnecessary:**
- The Sony SDIO experiment: the whole-card session uses it.
- The QR-code scan for the 1.0 route. (Active SSDP search stays open: see the multicast entitlement in section 4.)
- Repeating every Wi-Fi test on the home network: group B is optional.

**Out of scope for 1.0:** video and transfer-while-shooting (as in the proposal), and Bluetooth wake (the Wi-Fi switch-on comes into 1.0 only if decision 6 is taken). USB 3 is in 1.0 but stays unmeasured.
