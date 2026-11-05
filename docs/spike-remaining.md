# Rest of the spike: what remains before the product build (from 4 Nov)

Written Wednesday 4 Nov 2026 on spike build 14 (TestFlight 0.1 (14.1)). It rests on `docs/spike-findings.md`, including the home-network runs of 4 Nov 03:23–03:41 (PR #52), `docs/spike-plan.md`, `docs/spike-runbook.md` and `docs/proposal.md`. It proposes; the decisions stay with Shamil and the 13 Nov go/no-go.

## Decisions (Shamil, 2 Nov)

- **Wireless is in 1.0.** The wireless go/no-go is no longer whether to ship it but which path works and how well. PTP/IP browsing on the camera's access point is the first choice; if no camera mode lists the card, the camera's *Send to Smartphone* is the path. Iteration 3 is in 1.0 either way, so both need testing: every camera Wi-Fi mode, the join and pairing flow, resume after a drop, behaviour under lock, and the fallback.
- **Battery per GB and MP4 are out of the spike.** 1.0 imports stills; nothing in it depends on battery use per GB.
- **Scaling is measured, not assumed:** the guided *Scaling* run lists the card cold in MSC (and MTP), adds a burst of about 300 frames, lists again, and projects 2,000 and 5,000 files from the two sizes. (The burst was dropped on 3 Nov; see below.)
- **More of the testing runs as guided runs** in the spike's *Guided* tab (build 8), so each evening needs fewer builds and less reading of the runbook.

## Decisions (Shamil, 3 Nov)

- **Dropped:** *Smartphone Connect* (the Bluetooth switch-on is that connection), *Send to Smartphone* (the fallback isn't needed: the camera lists its card over PTP/IP), the RAW+JPEG / RAW+HEIF pairing test (Shamil shoots RAW only; the pairing rule stays the default: same folder, same stem, capture time within 1 s), and the 300-frame *Scaling* burst (projected from the listings already made; see *Wireless browsing in 1.0* in the findings).
- **Still to run (as of 3 Nov):** PC Remote over the home Wi-Fi, resume in MSC, PC Remote over USB, a real proximity arrival, *Copy all RAW to Files* over USB-C, the build 14 Bluetooth and copy runs, and Photos *Don't Allow* (last, on a fresh install). On 3–4 Nov the build 14 runs, the USB-C copy and the home-network runs were done (the idle run's Bluetooth-off phase didn't run, because the Wi-Fi was already off; it was done by hand on 5 Nov). What is left of this list, and what has come up since, is in section 2.

## Decisions (Shamil, 4 Nov)

- **Dropped:** *MSC: resume after a cable pull* (an ARW restarts in about 1 s over USB) and the locked-recovery Wi-Fi copy (a join needs the app in front).
- **Decision 2 is (d):** after an import, stay on the camera's network for a few minutes so a second import needs no prompt, then leave.

---

## 1. Where the spike stands

Every go/no-go row of the plan has an answer. Nothing below is waiting on a run to reach a decision on 13 Nov; the open runs settle details of 1.0 and complete the record.

| Question | Answer on 4 Nov | Findings section |
| --- | --- | --- |
| Wired import is viable | **Go.** MSC lists 391 files in 7.2 s (547 in 11.6 s) and downloads ARW at 39.9–41.7 MB/s. MTP downloads at 38–39 MB/s but takes 65 s to list, and JPG runs at 25.6 MB/s against 41.7 in MSC. The goal is ≥ 25 MB/s. A USB import stops 30 s after the app leaves the foreground (MSC and MTP tested). | *Wired import is viable* |
| Byte-range resume on USB | **Go.** GetPartialObject in MTP, cable pulled at 47 %, resumed after the replug, SHA-256 match. MSC (`requestReadData` at an offset) is untested and not needed for 1.0: an ARW restarts in about 1 s over USB (decision 7). | *Byte-range resume on USB* |
| Wireless browsing in 1.0 | **Go.** On the camera's own network, PC Remote lists 391–419 files in 4.7–5.0 s and downloads ARW at 11.7–15.5 MB/s against the 8 MB/s criterion. On the home network, after the camera's access authentication was turned off: 549 objects in 7.7 s and 10.2 MB/s (one run, app in front). Both need Sony's whole-card contents transfer; a plain session lists nothing. | *Wireless browsing in 1.0* |
| SSDP discovery | **The camera announces and the phone hears it without the multicast entitlement**, on its own network (0.73 s) and on the home network (1.9 s and 4.65 s into a 5 s listen). How often it announces isn't measured. It doesn't answer a unicast M-SEARCH. The plan's literal criterion (entitlement granted) can't be shown unless Apple has granted it; the request's status isn't recorded. | *SSDP discovery* |
| Transfer-while-shooting | **Go over Wi-Fi.** Sony's ObjectAdded (0xC201) arrives in PC Remote on both networks. Not shown over USB: not advertised in MTP; in PC Remote it is advertised, but none arrived on a plain ImageCaptureCore session without Sony's init sequence (4 Nov 12:10). | *Transfer-while-shooting feasible later* |
| Proximity reminder in 1.0 | **Go.** The camera advertises service UUID 1800 on, asleep and off; a background scan woke the locked phone from the next room in 11.76 s and the reminder posted 0.02 s later. A real arrival is untried. | *Proximity reminder in 1.0* |

**What the spike learnt that changes 1.0's design** (detail in section 5):
- A USB import longer than about 30 s needs the app in front; over Wi-Fi a continued task kept a 360-file copy (15.25 GB) going for nearly 13 minutes in the background, 329 s of it locked; the task ran 983 s in all without expiring.
- The camera sometimes drops its card and Wi-Fi; the copy recovered itself from a restart in 97 s, with the app in front.
- Bluetooth switches the camera's Wi-Fi on in 0.8–2.7 s and hands over the network details, after a pairing the app can make itself with the camera's *Pairing* screen open (no Creators' App; one run, 4 Nov); an unused Wi-Fi goes off about 50 s after it comes on (49.8–50.0 s in seven runs, and with the Bluetooth link closed too), and one with the phone joined stays up (at least 13 minutes, 4 Nov).
- Handles are stable across sessions, so only the first import lists everything (5.9–8.3 s at 555 handles, 8.4–9.1 s at 741).
- Photos needs read/write access, but *Limited Access* with nothing selected is enough.

## 2. Still to run on build 14.1

No new build is planned. Every run below exists on 14.1 (checked in `Spike/Sources/Guided/GuidedScripts.swift`). Times are the guided runs' own estimates. "Plan record" means it fills a findings cell the plan asks for and is not needed for the decision; "1.0 design" means it settles a decision in section 5; "Optional" means skipping it costs a blank cell or a provisional decision.

**A. USB: one session, camera on the cable (about 10 min, all optional)**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Camera and Photos checks* | Does Photos › Import show the card's JPGs (187 are on it)? It is the plan's day-1 pass criterion and has no result. (Whether the USB mode can be fixed is answered: yes.) | 3 min | Plan record (optional) |
| *USB: thumbnail speed-ups* | Thumbnails with 1, 2 and 4 in flight; previews from file headers. Sets the Browse pipeline (USB thumbnails take 145–188 ms against the 50 ms target). | 5 min | Optional |

Done on 4 Nov (11:30): the copy in MTP, with the app sent to the background. ImageCaptureCore suspends 30 s after the app leaves the foreground, as in MSC, and iOS ended the continued task each time (Stop ruled out). No copy ran in *Remote Shoot (PC Remote)*: the camera went to a settings page (*Img Dest*) (Shamil). The copy run doesn't refuse that mode; at 12:10 ImageCaptureCore turned out to list no files there (below), which fits. At 11:56 a copy in MSC showed the same 30 s and expiry, and Shamil's cable pull during it ended the copy (49 of 362 copied, the file in flight failed). It stands in for the *MSC: resume after a cable pull* run, dropped the same day (decision 7). At 12:10 *PC Remote: DeviceInfo and ObjectAdded* answered the PC Remote question, from a session already open on the same plug-in: ImageCaptureCore lists no files in *Remote Shoot (PC Remote)*, and no ObjectAdded arrived over USB after a shot on a plain session, though DeviceInfo there matches PC Remote over Wi-Fi (81 operations, firmware 2.01).

**B. The camera on the home network** (camera joined to the home Wi-Fi, PC Remote Function on, *PC Remote Cnct Method* = *Wi-Fi Access Point*, access authentication off; what that setting costs in security is a question in section 3).

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Wi-Fi: one camera mode* › *PC Remote (home Wi-Fi)* | Does the first handshake still take 40 s, or is it quick now (the 4 Nov run took 40.2 s, then 6 ms)? | 15 min | Optional (1.0 design if the home route is kept) |
| *Copy all RAW to Files* › *Wi-Fi* › *Home LAN* | A whole card over the home network. The 03:30 attempt was refused (access authentication was on then), so the only figure is 20 ARW at 10.2 MB/s. | 10–35 min | Optional |
| *Wi-Fi: GUID after a power cycle*, *Wi-Fi: resume after Wi-Fi off* and *Wi-Fi: lock during a transfer*, on the home network | Does the camera accept the phone again after a restart with no wait, and does that first connection take 40 s again (its handshake time is logged)? The home-network cells for partial reads, resume and lock are blank. | 5, 5–8 and 8 min | Optional |

**C. The camera's own network (the 1.0 route)**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |

Done on 5 Nov (01:27–02:21), by hand on the Bluetooth tab: five more unused switch-ons went off 49.8–50.0 s after status 2, and with the Bluetooth link closed the Wi-Fi went off too (by 77 s). After a camera restart, *Read details and join* joined first time, with CC09's tag 0x0003 at 1, so a restart alone doesn't explain the 12:34 failure (decision 3); the Bluetooth link then dropped by itself 11 s after the join. The second-write test didn't happen: each write came after the previous Wi-Fi had gone off (proposed for dropping, section 7).

Done on 5 Nov (00:58–01:25): Creators' App paired again reused the iPhone's pairing with no prompt, and both apps worked; the pairing survived a camera restart, read on our app's own link (decision 6).

Done on 4 Nov (12:39–12:54): the stay-joined test. The camera kept its Wi-Fi up for at least 13 minutes after the session while the phone stayed joined, through background spells and a lock (decision 2). A first attempt at 12:34 failed to join although `apply` returned without an error; nothing had changed before the attempt at 12:39, which joined (decision 3). At 13:03–13:06 the hand-off without Creators' App's pairing: refused while unpaired, then, with the camera's Bluetooth *Pairing* screen open, the app paired itself and the hand-off ran end to end (decision 6).

**D. Proximity reminder**

| Run | Answers | Time | Needed for |
| --- | --- | --- | --- |
| *Bluetooth: proximity reminder* | The same-room case with the scan started after the lock, which the 2 Nov result (build 8, TestFlight 0.1 (6.1)) couldn't show, then the next room. | 10 min | Optional (the "No" is the procedure, not the platform) |
| A real arrival, by hand (no guided run): Bluetooth tab › *Watch in background*, camera away long enough for iOS to forget it (for example in the car), phone locked, camera brought into range. Then the *Creators' App connected*, *quit* and *Kill app to test relaunch* rows. | Does iOS report the camera afresh on arrival, and does a relaunch after a kill work? (After a kill, iOS handed the scan back when the app was reopened, 5 Nov 02:16; a relaunch by iOS on arrival is untried.) | 10 min plus the time away | 1.0 design (the reminder's main case; decision 8) |

Done on 5 Nov (02:17): Bluetooth off and on in Settings. The app restarted its scan in the background and iOS reported the camera 0.03 s later; the spike's 60 s debounce held the reminder (decision 8).

**E. Photos *Don't Allow*, last, on a fresh install** (Background › *Photos albums, no camera*, runbook steps A1–A4). Deleting the app deletes the log, the fixtures and the default copy folder (move out any copies worth keeping), gives the Wi-Fi tab a new GUID and clears the Bluetooth proximity filter (retype it). Before it: *Export JSON*, *Copy measurements table*, *Share fixtures (zip)* and save them off the phone. About 10 min. Needed for: 1.0 design (the Photos permission flow).

**Not a run: a Bluetooth trace of Creators' App leaving.** Apple's Bluetooth logging profile on the phone and PacketLogger on the Mac, to find the write that switches the camera's Wi-Fi off about 1 s after Creators' App leaves. It decides decision 2 below. It needs the Mac and an evening; optional, but without it decision 2 is made on the measured behaviour alone. The 5 Nov 01:13 leave left the camera's Wi-Fi on for at least 59 s, so the write is also the only known way to make sure the Wi-Fi goes off after (d)'s leave.

**No guided run on 14.1 answers these; record as open unless done by hand.**
- A second CC08 write while the status is 2, and a write during status 3. The first was tried by hand on 5 Nov, but each write came after the previous Wi-Fi had gone off; it is proposed for dropping (section 7). A write during status 3 (1.4–4.5 s long) can't be timed by hand and needs a new build. (An unused Wi-Fi with the Bluetooth link closed was done by hand on 5 Nov: off within 77 s.)
- How often the camera announces on the home network: the runs listen for 5 s.
- Why the first Bluetooth connect takes 5–6 s (0.4 s otherwise) matters for time-to-camera; the camera seems slow to take the first connection after it has been idle. Not after every restart: 5.95 s after the 5 Nov 01:18 restart, 0.50 s after the 02:21 one.
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
   - `usb/deviceinfo.bin` and `usb/FIRMWARE` are PC Remote's since 4 Nov 12:10. They replaced MTP's from 1 Nov, the source of the Setup row's "2.0". PC Remote's DeviceInfo matches `ptpip/deviceinfo.bin` (475 B, the same codes), so capture MTP's again before the export: on the Wired tab, with the camera in MTP, tap *Open session*, then *GetDeviceInfo*. Its firmware string also settles the firmware question (decision 6).
5. Commit on a branch.

**Findings: the blank rows**
- *Setup:* card (type, files by kind), cable, home LAN (access point model and band; the network is UniFi behind a UniFi Security Gateway). The camera's band is 5 GHz only; its channel isn't known.
- *Menu wording:* twelve rows are empty: `Version`, `USB LUN Setting`, `USB Power Supply`, `Wi-Fi Connect`, `Access Point Set.`, `Wi-Fi Frequency Band`, `Smartphone Connect`, `PC Remote Function`, the two *PC Remote Cnct Method* values, *Pairing* (PC Remote) and `Select on Camera & Send` (mark that one "not used: dropped 3 Nov"). The names of the *Select on Connect* setting and of access authentication (with its path) are also unrecorded, and so are the wording of the camera's pairing confirmation (the path to the Bluetooth *Pairing* screen is MENU › Network › Bluetooth › Pairing), and whether it or iOS's request shows a code to compare (onboarding, decision 6, sends the person to that screen). `Version` also settles the firmware question in decision 6. Read them off the camera: the app's empty-state copy will use these words.
- *Open questions:* the USB 2 throughput row is blank (the numbers are in *Wired import is viable*; add the card type).
- *ImageCaptureCore facts:* two blank rows (`deviceDidBecomeReady` on a reopen; `ICCameraDevice.batteryLevel` against PTP BatteryLevel). Run or mark skipped.
- *Measurements:* don't paste *Copy measurements table* over the table: the phone's log has been cleared between runs (at 4 Nov 12:10 it held six measurements, and its USB "Time to enumerate 200 files" was the 0.03 s of PC Remote's empty catalogue). Fill the blank cells by hand, and mark each dropped cell "skipped (stills-only 1.0)" or "skipped (not a 1.0 decision)" rather than leaving it blank.
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
- *Background strategy:* "the USB session survives suspension" is true, but nothing transfers after 30 s; "the camera keeps the AP up for several minutes" holds while the phone stays joined (at least 13 minutes on 4 Nov, through background spells and a lock, with the Bluetooth link up). Once the phone left, it was about 50 s in two runs of three; after the 5 Nov 01:13 leave it was still up 59 s later.
- *Permissions:* `.addOnly` becomes read/write with Limited Access allowed.
- *Iteration 2:* "re-plugging after a pull resumes within 2 s" can't be met, because nothing answers until the catalogue is done (about 65 s in MTP, 7–12 s in MSC). *Iteration 4:* "lock the phone during a 2 GB import and it finishes" is about 50 s at 40 MB/s, so it fails over USB as written.
- *Iteration 3 and roadmap:* the QR scan is replaced by the Bluetooth hand-off, with a pairing the app makes itself, if decision 6 is taken, and 1.1's list (Bluetooth wake and credential hand-off) changes with it.
- *Risks and open questions:* tick the USB-mode and GUID open questions now. Answer ObjectAdded over USB: not in MTP; none in PC Remote on a plain session (4 Nov 12:10; Sony's init sequence over USB untried); and the USB 2 throughput one once the card type is recorded; retire the first two risks and the last (the camera keeps advertising when switched off); add the reverse-engineered Sony pieces, ImageCaptureCore's 30 s suspension and the camera dropping its card with Creators' App open.

**Iteration 1 backlog:** it is wired-only and still marked a draft. Finalise it on 13 Nov from the findings (section 6).

## 5. Design decisions for 1.0

Each is Shamil's. The recommendations are drawn from the findings; "provisional" means a run or an answer in sections 2 and 3 could change it.

**1. USB: the 30 s foreground limit.**
- *Evidence:* in MSC, ImageCaptureCore reports *will suspend* when the app leaves the foreground and *did suspend* 30.0–30.1 s later, in the background (five times of five: four at 01:57, one at 11:56) and under lock (03:07; nothing moved for the remaining 629 s). A continued task doesn't change it. The session survives, and *resumed operations* comes 0.3–0.9 s after the app returns. A full card of 360 ARW takes about 6½ minutes at 40 MB/s. MTP behaves the same (4 Nov 11:30, three of three). In *Remote Shoot (PC Remote)* ImageCaptureCore lists no files (12:10).
- *Recommendation:* the import asks to stay in front and keeps the screen on; the engine pauses on *did suspend* and continues when the app returns. A continued task over USB buys at most 30 s, so it isn't a requirement for wired. In PC Remote ImageCaptureCore lists no files, so the app asks for MSC or MTP there.
- *Provisional on:* nothing pending (PC Remote answered 4 Nov 12:10).

**2. Wi-Fi: leave the camera's network after an import, or stay joined.**
- *Evidence:* in two runs (3 Nov 22:43, 4 Nov 13:06), removing the hotspot configuration 45–46 s after CloseSession made the camera's Wi-Fi start switching off 51.0–51.2 s later and be off at 53.0–53.2 s, with no write. A third leave (5 Nov 01:13; Creators' App open, as it was at 22:43) didn't switch it off within the 59 s watched, so the switch-off after a leave isn't always within a minute. Removing it brings the iOS join prompt back; re-applying a saved configuration (the 01:12 recovery) didn't prompt. If the phone stays joined, the camera's Wi-Fi stays up: status 2 for at least 785 s after CloseSession on 4 Nov, through background spells and a 73 s lock, with the app's Bluetooth link up and Sony's notifications on throughout (with the link closed, only 63–64 s is tested), and the phone's internet on mobile data meanwhile. Creators' App's Wi-Fi goes off about 1 s after it leaves; how isn't known. The camera's battery cost of a Wi-Fi left on isn't measured.
- *Options:* (a) leave after each import: a join prompt every time, the camera's Wi-Fi off about 53 s later in two runs of three (still on 59 s after the 5 Nov leave); (b) stay joined: no prompt, but the camera's Wi-Fi stays on while the phone is joined (at least 13 minutes measured) and the phone's internet goes over mobile data meanwhile; (c) (b) plus the write, if the trace finds it; (d) stay joined for a few minutes after an import, so a second import needs no prompt, then leave (the app has to be running then to remove its configuration; doing that from the background is untested).
- *Decision (Shamil, 4 Nov):* (d). (b) alone would leave the camera's Wi-Fi on and the phone on mobile data while they're together (at least 13 minutes measured; longer, and the battery cost, untested). (c) stays open if the trace finds the write. Still to settle in Iteration 3: how long to stay, and leaving with the app in the background.

**3. Wi-Fi: join promptly, and recover.**
- *Evidence:* the camera gives about 50 s from status 2 (*terminating* at 49.8–50.0 s in seven runs; with the Bluetooth link closed it was off by 77 s); the joins took 7.4–10.6 s with the prompt. In the 4 Nov recovery, two fixed 30 s waits made up 62 of 97 s. The second was waiting for iOS to rejoin; the first was waiting for the port. Only the join is known to need the foreground.
- *Recommendation:* confirm a join by the camera's gateway on the Wi-Fi path, not by `apply` returning, and try again if the gateway doesn't come (at 12:34 on 4 Nov `apply` returned without an error and the join failed; the next attempt, with nothing changed, joined; a join straight after a camera restart worked first time on 5 Nov, so a restart alone doesn't explain it). Join as soon as CC09 reports status 2; watch CC09 during the join prompt and, if it reaches 3 or 0, write CC08 = 0x01 again and retry. Don't count on the Bluetooth link after the join: on 5 Nov it dropped by itself 11 s after one (a CoreBluetooth internal error), so the app reconnects when it next needs CC09. Removing the second wait is measured (join as soon as CC09 reports 2). The first wait, before going to Bluetooth, may have to stay: the app can't yet tell a camera that is back on from one the person switched off, and 1.0 shouldn't switch on the latter. Keep a wait, and treat how to tell them apart as open. A join needs the app in front. Apple's hotspot API has an error for an app that isn't in the foreground (`applicationIsNotInForeground`), and the spike's recovery doesn't try the join unless the app is in front. At 01:08, with the home network in range, iOS didn't rejoin the camera's network by itself in 30 s (with no other known network in range: untested). So with the app away, the copy does what needs no join: it waits for the card, reconnects, switches the camera's Wi-Fi on over Bluetooth if allowed, and waits for iOS to rejoin. If a join is still needed, it pauses and notifies, and joins when the app returns. The spike's copy ends at that point instead of pausing, so this pause is new in 1.0.
- *Provisional on:* nothing pending: the locked-recovery run was dropped (Shamil, 4 Nov). Left unmeasured: a Bluetooth switch-on from the background, and whether iOS rejoins by itself while the phone is locked.

**4. Pause, continue and stalled files.**
- *Evidence:* both Wi-Fi expiries came as the Camera app was opened. The three USB expiries came 31–74 s after the progress last moved, during ImageCaptureCore's suspension: two in the 01:57 copy, phone unlocked, with what was in front not recorded, and one in the 03:07 run with the phone locked (Stop in the Live Activity not ruled out). Four more, three in the 11:30 MTP copy (34–59 s) and one in the 11:56 MSC copy (36 s), came after the progress stopped, phone unlocked, with Stop ruled out by Shamil; yet in the 01:57 copy three stalls went about 60 s without progress without one (two of them were 109–114 s without a byte, with a failed file moving the progress at 60 s). *Continue* started a new task in 0.03 s and copied again 11 s after the tap, 8.3 s of it a relist that stable handles make unnecessary; the file in flight restarted from its start. Over USB the same `requestDownload` survived a 632 s suspension, yet the spike's 60 s limit failed three downloads. Over Wi-Fi a drop made the copy count 82 files as failed before the link closed.
- *Recommendation:* treat expiry as normal: pause, notify, and on Continue start a new task, reopen, ask for new handles only, and resume at the file in flight. Report progress in bytes. A stall pauses and retries; "failed" is for real errors, with a limited number of retries. A cable pull or other loss of the camera pauses the copy too, without failing the file in flight. Once the camera is back and listed again (11.3 s for 549 files in MSC, 65–82 s in MTP), the copy carries on: it finds the files left by identity (decision 7) and copies the file in flight again from its start. In the 11:56 run the spike's copy ended instead, and the file in flight was counted as failed.

**5. The home network as a second route.**
- *Evidence:* works after a one-time camera setup (home Wi-Fi, PC Remote Cnct Method *Wi-Fi Access Point*, access authentication off); no join prompt (whether the phone keeps its internet wasn't checked); the app can find the camera by listening for its announcements; the first handshake took 40.2 s (the app must wait at least that long). Slower so far: 10.2 against 11.7–15.5 MB/s, thumbnails 48 against 35–39 ms. One run, app in front. Whether the Bluetooth switch-on works with the camera on the home network is untested.
- *Recommendation (provisional):* the camera's own network over Bluetooth stays the 1.0 route; the home network is supported when the camera is already on it, after Iteration 3's core. Decide after group B and the answer on what turning access authentication off costs in security (section 3).

**6. Sony-specific operations and the Bluetooth hand-off.**
- *Evidence:* a plain PTP/IP session gets StoreNotAvailable; listing needs SDIO_OpenSession (0x9210), Sony's init sequence and 0x9212, and resume needs 0x9211. The Bluetooth hand-off comes from reverse-engineered notes and has worked on this body with Creators' App's pairing and, on 4 Nov, with a pairing the app made itself: with the camera's Bluetooth *Pairing* screen open, iOS's pairing request and a confirmation on the camera, then the full hand-off (13:06). Unpaired, the camera refuses the reads and the switch-on and drops the link (13:03). The proposal says 1.0 uses neither, for two reasons: fragility against firmware updates and App Store review. Both still apply; the DeviceInfo check and per-firmware fixtures address the first, and nothing yet addresses the second. Without the hand-off the person switches on PC Remote Function and joins in Settings, as on 2 Nov. USB DeviceInfo reported "2.0" in MTP and "2.01" in PC Remote (as over PTP/IP and Bluetooth) on the same body; reading Setup › Version settles it.
- *Recommendation:* accept both. Read the operation list from DeviceInfo before using any Sony operation (as build 9.1 does), keep Sony-specific code in one place, keep fixtures per firmware (as general advice), and move the Bluetooth hand-off from 1.1 into Iteration 3. Shamil's 3 Nov decision already treats the Bluetooth switch-on as the smartphone connection. The trade-off against the two costs above is Shamil's.
- *Onboarding:* one pairing from the app, with the camera's Bluetooth *Pairing* screen open; Creators' App isn't needed.
- *Provisional on:* nothing pending. The iPhone's pairing is shared: Creators' App, added after ours, reused it with no prompt, both apps worked (5 Nov 00:58–01:25), and the pairing survived two camera restarts (01:18 and 02:21). Not tried: Creators' App's automatic transfer during our import, and a reinstalled app.

**7. Wired mode, identity and resume.**
- *Evidence:* MSC lists 9 × faster and runs JPG 60 % faster; MTP has stable object identifiers and GetPartialObject. In MSC the PTP flag is misleading. A 40 MB ARW restarts in about 1 s over USB.
- *Recommendation:* support both and recommend MSC in the app's copy; branch on transport type, not `acceptsPTPCommands`; one import path (`requestDownloadFile`); after a replug, copy the interrupted file again from its start. Identity: `PersistentUniqueObjectIdentifier` in MTP (about 385 ms per object, so read it only for new objects; MTP handles were also stable across a replug); folder, name, capture date and size in MSC. Byte resume is low priority for wired stills and matters for Wi-Fi (0x9211). Show the last-known card at once while ImageCaptureCore lists.
- *Provisional on:* nothing pending. The *MSC: resume after a cable pull* run was dropped on 4 Nov (Shamil): an ARW restarts in about 1 s, and the 11:56 cable pull showed what a copy does. In MSC the card is a mounted file system, so folder and name shouldn't change across a replug; that isn't tested after a replug.

**8. Proximity reminder requirements.** Record these in the proposal and the Iteration 4 backlog; they need no decision beyond the wording ("nearby", not "switched on"). Confirm the camera after a wake by the stored peripheral identifier, or by Sony's company ID together with the name, because 1800 is a generic service. The trigger is coming into range: the advertisement is identical on, asleep and off. Restart the scan from a wake, not a timer, and when Bluetooth comes back on (the spike did so in the background and iOS reported the camera 0.03 s later, 5 Nov); hold reminders while connected or importing (the camera advertises while our app is connected too), and hold further reminders for a long time after one (in the background iOS reported a camera that came and went within range 137 times in 10 hours, 4–5 Nov); ask for notification permission when the person switches the reminder on.

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

**Dropped by Shamil (2–4 Nov):**
- All MP4 rows, the 1 GB clips and the 4 GiB / 0x95C1 question (1.0 is stills only), and battery per GB on every link (2 Nov).
- *Smartphone Connect*, *Send to Smartphone*, the RAW+JPEG pairing test and the 300-frame *Scaling* burst (3 Nov; projected: see the findings).
- *MSC: resume after a cable pull* (4 Nov): an ARW restarts in about 1 s over USB, and the 11:56 cable pull showed what a copy does.
- The locked-recovery Wi-Fi copy (4 Nov): the earlier runs already copied a whole card in the background and under lock (23:18), paused and continued (23:51) and recovered from a camera restart with the app in front (01:08). Under lock the spike's recovery would switch the camera's Wi-Fi on over Bluetooth and wait 30 s for iOS to rejoin, but it doesn't try its own join unless the app is in front (Apple's hotspot API has an error for an app that isn't: `applicationIsNotInForeground`), and at 01:08 iOS didn't rejoin by itself in 30 s, so the recovery would most likely fail and the spike's copy end. Left unmeasured: a Bluetooth switch-on from the background, and whether iOS rejoins the camera's network by itself while the phone is locked.

**Proposed drops, not yet confirmed by Shamil** (section 3):
- A 2,000-file card in MTP.
- More MTP listing experiments (GetObjectPropList variants, PTP listing): the camera sets the pace.
- Instruments Allocations and the Energy gauge (the app's own probe peaked at 70 MB over USB and up to 113 MB over Wi-Fi, against the 150 MB budget).
- Mac gphoto2 and Image Capture probes, and the Mac day-6 probes as a required step: the phone did the same work.
- BLE: all nine power × pairing combinations.
- The Photos Import RAW-only mystery (not our app's path).
- Wi-Fi two in flight (one transaction per PTP/IP session).
- The second-write test (a second CC08 = 0x01 while the status is 2; group C): tried by hand on 5 Nov, but each write came after the previous Wi-Fi had gone off. 1.0 doesn't depend on it: it writes CC08 again whenever CC09 shows 3 or 0 (decision 3).
- The second MTP lifecycle run as a separate run; it came back as the MTP copy in group A, run on 4 Nov 11:30, because users will land in either USB mode.

**Now unnecessary:**
- The Sony SDIO experiment: the whole-card session uses it.
- The QR-code scan for the 1.0 route. (Active SSDP search stays open: see the multicast entitlement in section 4.)
- Repeating every Wi-Fi test on the home network: group B is optional.

**Out of scope for 1.0:** video and transfer-while-shooting (as in the proposal), and Bluetooth wake (the Wi-Fi switch-on comes into 1.0 only if decision 6 is taken). USB 3 is in 1.0 but stays unmeasured.
