# 13 Nov decision pack

Prepared 7 Nov 2026 for Shamil's go/no-go on Fri 13 Nov, from [spike-findings.md](spike-findings.md), [spike-remaining.md](spike-remaining.md), [proposal.md](proposal.md), [spike-plan.md](spike-plan.md), [iteration-1-backlog.md](iteration-1-backlog.md) and [iteration-3-4-backlog.md](iteration-3-4-backlog.md) as they stood on 7 Nov.

Only these are decided: wireless in 1.0 and the drops listed under "Decisions (Shamil, 2 Nov / 3 Nov / 4 Nov)" in spike-remaining.md, decision 2 = (d), and Shamil's 1 Nov album and RAW+JPEG original defaults (iteration-1-backlog.md, section 5). Everything else in section 5 is a recommendation and is written as one, with its decision number. Numbers carry the hedges the findings give them ("one run", "MTP only", "untested"); a figure that wasn't measured says so.

**How to use it**
1. Part 1: work down the six rows, write Go or No-go in the last column, then paste both tables over the empty "Go/no-go decision record" section at the end of the findings.
2. Part 2: write a choice against each of decisions 1–9 (decision 2 is already made).
3. Part 3: apply the changes to the live proposal, then fill the last three lines of the decision record. `proposal.md` and `spike-plan.md` are exports of the live doc, so they are not edited here.

**What could still move a cell before 13 Nov** (all optional or open in spike-remaining.md, sections 2 and 3): the Photos *Don't Allow* run on a fresh install (decision 9); the home-network runs, group B (decision 5); a walk into range (decision 8); the Bluetooth trace of Creators' App leaving (decision 2's open part); the blank setup rows (card type, cable). The fixtures also still need the Mac (section 4).

---

## Part 1. Draft go/no-go decision record

For the end of `spike-findings.md`. It keeps that section's shape (an item table, then a question table) and adds a *Decision* column. The date and decider are filled as drafts; change them if the decision slips.

### Go/no-go decision record

| Item | Value |
| --- | --- |
| Decided on | 13 Nov 2026 |
| Decided by | Shamil |
| Wireless scope for 1.0 | **In 1.0** (Shamil, 2 Nov: the question became which path works and how well). **Path:** PTP/IP browsing on the camera's own access point, in *PC Remote*, through Sony's whole-card contents transfer. The *Send to Smartphone* fallback isn't needed (dropped 3 Nov: the camera lists its card over PTP/IP). The path needs Sony's operations, whose costs are part of decision 6 (recommended, not yet decided), as is how the phone joins the camera's network: Bluetooth hand-off after one in-app pairing, or the person joins in Settings. The home network as a second route is decision 5 (recommended, provisional). |

| Question | Result | Numbers behind it | Decision |
| --- | --- | --- | --- |
| Wired import is viable | **Go.** `ImageCaptureCore` lists the card and downloads in both *Image Transfer* modes on a USB 2 iPhone, above the 25 MB/s floor. MSC is faster on every count. A USB import stops 30 s after the app leaves the foreground (MSC and MTP tested), so a long one needs the app in front (decision 1, recommended). In *Remote Shoot (PC Remote)* it lists no files. | **MSC:** 391 files listed in 7.17 s (12.23 s on the first run), 547 in 11.61 s (4 Nov); ARW 39.89 MB/s one at a time, 41.73 MB/s two in flight; JPG 41.66 MB/s. **MTP:** 391 files in 64.96 s, 549 in 82.14 s (4 Nov), 825 in 122.72 s (5 Nov); ARW 38.19 and 39.05 MB/s; JPG 25.61 MB/s. 20 ARW were 839 MB and 20 JPG 440 MB, one run each; memory peaked at 70–71 MB. Whole-card copies of 360–362 ARW (15.25–15.34 GB) ran at 37.4–42.6 MB/s, in front or in the background, until the 30 s stop (three copies on 4 Nov: two in MSC, one in MTP). *Did suspend operations* came 30.0–30.1 s after *will suspend* (30.0–30.3 s after the app left the foreground), in the background and locked. Card type and cable aren't recorded; USB 3 is unmeasured. | Go / No-go: ____ |
| Byte-range resume on USB | **Go, verified with a cable pull (MTP).** Not needed for wired 1.0 if decision 7 is taken (recommended: an ARW restarts in about 1 s over USB). MSC (`requestReadData` at an offset) is untested. | `GetPartialObject` (0x101B) read the newest ARW (40.3 MB) at 37.29 MB/s, 10.8 % below `requestDownload` (41.81 MB/s; the plan allows 15 %). Cable pulled at 47 % (offset 18,874,368); after the replug it resumed at that offset and the SHA-256 matched. Over Wi-Fi, Sony's 0x9211 resumed after Wi-Fi was cut at 54 %, SHA-256 matching (2 Nov, one run). Files of 4 GiB or more can't be read in ranges (32-bit offsets); 1.0 is stills only. | Go / No-go: ____ |
| Wireless browsing in 1.0 | **Go.** On the camera's own network, *PC Remote* lists the whole card and downloads ARW at 11.7–15.5 MB/s against the 8 MB/s criterion, once the session is opened with Sony's whole-card contents transfer (a plain session gets StoreNotAvailable). The home network also works after the camera's access authentication was turned off: one run, app in front. | **Camera's network:** 391 files in 4.74 s and 419 in 4.95 s (2 Nov; the plan's target is 200 files in ≤ 5 s); 5.9–8.3 s at 555 handles, 8.42–9.11 s at 741 (5 Nov); card ready about 2.0–2.6 s after the session opens (2.99 s on the home network). 20 ARW (954 MB) at 15.5 MB/s, a second run 11.7 MB/s; whole-card copies at 12.6–17.4 MB/s (360 ARW, 15.25 GB: 16.4 min in one run with no pause, 15.0 min with one pause and continue, 20.1 min with a camera restart that recovered in 97 s, app in front). Thumbnails 35–39 ms each (50). Joining over Bluetooth: the camera answered 13.8–18.8 s after Start (29.5 s in the one run that included the first pairing). **Home network:** 549 objects in 7.73 s, 20 ARW at 10.18 MB/s, thumbnails 48.1 ms (one run). | Go / No-go: ____ |
| SSDP discovery | **The camera announces, and the phone hears it without the multicast entitlement.** The plan's literal criterion (entitlement granted) can't be shown unless Apple has granted it: the request's submission and status aren't recorded. spike-remaining.md (section 4) gives two options: record this as Go on passive listening and skip the request, or submit anyway to keep active search open. Shamil's choice (Part 2, other choices). | Own network: first NOTIFY 0.73 s after joining, with no multicast key in the build. Home network: four NOTIFYs, 1.91 s and 4.65 s into 5 s listens (4 Nov). No answer to a unicast M-SEARCH; our own multicast M-SEARCH never went out; Bonjour found no `_ptp._tcp` in 5 s. How often the camera announces is not measured. On its own network discovery isn't needed: the camera is at 192.168.122.1. | Go / No-go: ____ |
| Transfer-while-shooting feasible later | **Go, over Wi-Fi.** Not shown over USB. Out of 1.0 (as in the proposal). | Sony's ObjectAdded (0xC201) came about 0.4 s after the capture in *PC Remote* on the camera's network (2 Nov 22:50), and twice for two shots on the home network (4 Nov). USB: not advertised in MTP; in *Remote Shoot (PC Remote)* it is advertised, but none arrived in a 60 s watch on a plain `ImageCaptureCore` session (4 Nov 12:10; Sony's init sequence wasn't sent over USB). | Go / No-go: ____ |
| Proximity reminder in 1.0 | **Go.** The camera advertises a stable service UUID in every power state, and a background scan filtered on it woke the locked phone and posted the reminder. The UUID (1800, Generic Access) isn't Sony-specific, so the app confirms the camera after a wake. The advertisement can't tell on from off. | Advertises on, asleep and off (Creators' App quit); service 1800, Sony's company ID 0x012D. Next room, phone locked: reported after 11.76 s (RSSI −83 dBm), reminder 0.02 s later. 5 Nov: a camera back from its Airplane Mode was reported within about 3 s with the phone locked, and iOS relaunched a killed app to report it (the 23.23 s logged includes steps by hand). A walk into range is untried. In the background, iOS reported the camera 137 times in 10 hours (4–5 Nov), so the spike's 60 s debounce let 38 reminders through. | Go / No-go: ____ |

Changes made to [proposal.md](proposal.md) (transport table, performance budget, roadmap): _to fill_ (Part 3 of `decision-pack.md`)

Iteration 1 backlog finalised ([iteration-1-backlog.md](iteration-1-backlog.md)): _to fill_

Iterations 3 and 4 backlog finalised ([iteration-3-4-backlog.md](iteration-3-4-backlog.md)): _to fill_

---

## Part 2. Design decisions 1–9

Source: spike-remaining.md, section 5. "Provisional" means a run or an answer could still change it. Write the choice in the last column: *Accept* to take the recommendation as written, or the alternative.

| # | Question | Recommendation | Status | Still provisional | Shamil's choice |
| --- | --- | --- | --- | --- | --- |
| 1 | USB: the 30 s foreground limit. What does a wired import do when the app leaves the foreground? | The import asks to stay in front and keeps the screen on; the engine pauses on *did suspend* and continues when the app returns. A continued task buys at most 30 s over USB, so wired doesn't need one. In *Remote Shoot (PC Remote)* `ImageCaptureCore` lists no files, so the app asks for MSC or MTP. | Recommended, Shamil to decide | Nothing pending (PC Remote answered 4 Nov 12:10). | ____ |
| 2 | Wi-Fi: leave the camera's network after an import, or stay joined? | Not applicable: **(d)**, stay joined for a few minutes after an import so a second import needs no prompt, then leave. | **Decided by Shamil, 4 Nov** | Still to settle in Iteration 3: how long to stay, and leaving with the app in the background (untested; the app has to be running to remove its configuration). (c), (b) plus a Bluetooth write, stays open only if the trace finds the write. The camera's battery cost of a Wi-Fi left on isn't measured. | **(d)**, decided |
| 3 | Wi-Fi: how to join promptly, and recover from a drop. | Confirm a join by the camera's gateway on the Wi-Fi path, not by `apply` returning, and retry. Join as soon as the camera reports status 2. Watch the status during the join prompt and, if it reaches 3 or 0, write the switch-on again and retry. Don't count on the Bluetooth link after the join. Keep a wait before going to Bluetooth in a recovery (the app can't yet tell a camera that is back on from one the person switched off). A join needs the app in front; with the app away, the copy does what needs no join, and otherwise pauses, notifies and joins on return. | Recommended, Shamil to decide | Nothing pending (the locked-recovery run was dropped, 4 Nov). Unmeasured: a Bluetooth switch-on from the background; whether iOS rejoins the camera's network by itself while locked, or with no other known network in range. | ____ |
| 4 | Pause, continue and stalled files. | Treat expiry as normal: pause, notify, and on *Continue* start a new task, reopen, ask for new handles only and resume at the file in flight. Progress in bytes. A stall pauses and retries; "failed" is for real errors, with a limited number of retries. A cable pull or other loss of the camera pauses the copy without failing the file in flight. | Recommended, Shamil to decide | Why iOS ends a task isn't known (it gives no reason; both Wi-Fi expiries came as the Camera app was opened). Questions waiting on Shamil: was Stop tapped in the 03:07 USB lock run, and what was in front during the 01:57 USB spells and the 23:51 Wi-Fi spells. | ____ |
| 5 | The home network as a second route. | Provisional: the camera's own network over Bluetooth stays the 1.0 route. The home network is supported when the camera is already on it, after Iteration 3's core. | Recommended (provisional), Shamil to decide | Group B runs (optional); what turning access authentication off costs in security, to check before 1.0 asks anyone to do it; one run so far, app in front; the Bluetooth switch-on with the camera on the home network is untested, and whether the phone keeps its internet on the home route wasn't checked. | ____ |
| 6 | Sony-specific operations and the Bluetooth hand-off: accept both costs the proposal named (fragility against firmware updates; App Store review)? | Accept both. Read the operation list from DeviceInfo before using any Sony operation, keep Sony-specific code in one place, keep fixtures per firmware, and move the Bluetooth hand-off from 1.1 into Iteration 3. Onboarding is one pairing from the app, with the camera's Bluetooth *Pairing* screen open; Creators' App isn't needed. The trade-off against the two costs is Shamil's. Without the hand-off the person switches on PC Remote Function and joins in Settings. | Recommended, Shamil to decide | Nothing pending. Nothing yet addresses the App Store review cost. Not tried: Creators' App's automatic transfer during our import, and a reinstalled app. The app's own pairing worked in one run (4 Nov). | ____ |
| 7 | Wired mode, identity and resume. | Support both modes and recommend MSC in the app's copy; branch on transport type, not `acceptsPTPCommands`; one import path (`requestDownloadFile`); after a replug, copy the interrupted file again from its start. Identity: `PersistentUniqueObjectIdentifier` in MTP (about 385 ms per object, so only for new objects); folder, name, capture date and size in MSC. Show the last-known card at once while `ImageCaptureCore` lists. Ask it for thumbnails two at a time; in MTP don't read previews from the files unless the grid needs more than ImageCaptureCore's thumbnail (most likely the camera's 160 × 120). | Recommended, Shamil to decide | Nothing pending (*MSC: resume after a cable pull* dropped 4 Nov). Untested: MSC identity after a replug; MSC thumbnails two at a time (one run each in MTP: 73.0, 80.8 and 87.6 ms); previews read from files in MSC. | ____ |
| 8 | Proximity reminder requirements. Needs no decision beyond the wording ("nearby", not "switched on"). | Record the requirements in the proposal and the Iteration 4 backlog (Part 3, item 3.12): confirm the camera after a wake by stored identifier or by company ID with name; use state restoration; restart the scan from a wake, not a timer; hold reminders while connected or importing, over USB too, and for a long time after one; ask for notification permission when the person switches the reminder on. | Recommended, Shamil to decide (the wording) | A walk into range is untried. An app swiped away in the app switcher isn't relaunched (per Apple, untested); a relaunch after iOS ends a suspended app is per Apple, untested. | ____ |
| 9 | Photos access. | Ask for read/write and accept Limited Access with nothing selected; stage files as complete-until-first-unlock; find the album by its stored identifier. If *Don't Allow* isn't run, treat it as "import to Files only" and say so in the UI. | Recommended, Shamil to decide | The *Don't Allow* run on a fresh install is still to do (suggested Tue 10 Nov, section 2E). Whether Iteration 1 builds a Files-only path is Shamil's call (the proposal's 1.0 list has none). | ____ |

**Other choices waiting on Shamil** (spike-remaining.md, sections 3 and 4; not among decisions 1–9):
- **Multicast entitlement: submit or skip.** Passive listening worked without it on both networks; the announcement interval isn't measured, and 4.65 s was inside a 5 s listen. Either way the findings' entitlement section is filled and the proposal's wording changes (Part 3, item 3.11).
- **Bluetooth trace of Creators' App leaving:** wanted or not. It needs the Mac and an evening; without it decision 2 rests on measured behaviour alone.
- **The proposed drops in section 7** (A 2,000-file card in MTP; more MTP listing experiments; Instruments Allocations and the Energy gauge; Mac `gphoto2`, Image Capture and day-6 probes; all nine BLE power × pairing combinations; Wi-Fi two in flight; the second-write test; the separate second MTP lifecycle run): do they stand?

---

## Part 3. Changes for the live proposal

Each item gives the proposal section, the current text as it stands in `docs/proposal.md`, the text as it should read, and the evidence. Items 3.1–3.10 and 3.17 are the "Proposal updates" in spike-remaining.md, section 4 (3.17 is its Photos-import note, kept apart because the positioning is Shamil's), and 3.11 is section 4's "Multicast entitlement: submit or skip" item. Items 3.12–3.16 and 3.18 aren't listed there; they follow from decisions 5–8, the wireless finding (3.13) and the plan's day 10, and are marked so. Replacements that depend on a decision say which. 3.1 and 3.9 also say what to do if it goes the other way; for the others, reword the proposal then, because the findings contradict the current text of 3.2, 3.5, 3.8 and 3.14 whichever way the decision goes. Targets are Shamil's: where a measured figure replaces a target, the new target is left for Shamil to set.

### 3.1 Transports table, Bluetooth row (status cell) · depends on decision 6

**Current:** "1.0 for proximity detection (advertisement match only, no GATT traffic); camera wake and Wi-Fi credential hand-off later — Sony's GATT profile is undocumented and only the remote-shutter part is well understood by the community"

**Proposed (if decision 6 is taken):** "1.0 for proximity detection (advertisement match, then confirmation by the stored peripheral identifier) and for the Wi-Fi hand-off: after one pairing made from the app, it subscribes to Sony's status notifications, writes one characteristic to switch the camera's Wi-Fi on and reads the network name and password. Sony's GATT profile is undocumented: the characteristics come from reverse-engineered notes, checked on the α7C II (firmware 2.01) and unverified on other bodies or firmware."
If decision 6 is not taken: keep the current text, and say the person switches on PC Remote Function and joins in Settings.

**Evidence:** *BLE advertisement*, third run and *Without Creators' App's pairing*: Wi-Fi on in 0.8–2.7 s, details read first time, pairing made by the app in one run (4 Nov).

### 3.2 "Why we do not use Sony's own protocols" · depends on decision 6

**Current:** "Reverse-engineering it would make the app fragile against firmware updates and is a poor fit for App Store review. PTP is standardised, stable since 2005, and what Sony itself relies on for PC Remote and MTP import."

**Proposed (retitle "Where we use Sony's own protocol, and why"):** "PTP is standardised and stable since 2005, and it is the base of everything here. On the α7C II three things still need Sony's own operations. Listing the card over Wi-Fi needs SDIO_OpenSession (0x9210), Sony's init sequence and SDIO_SetContentsTransferMode (0x9212); a plain session gets StoreNotAvailable. Resuming a Wi-Fi download needs Sony's 0x9211, because the standard `GetPartialObject` answers InvalidObjectHandle there. Wi-Fi `ObjectAdded` events are Sony's 0xC201. The Bluetooth hand-off (see the transports table) writes Sony's characteristics. The two costs the original paragraph named remain: fragility against firmware updates and App Store review. The first is handled by reading the operation list from DeviceInfo before using any Sony operation, keeping Sony-specific code in one place and keeping fixtures per firmware (the firmware string depends on the mode: "2.0" in MTP, 2.01 in PC Remote and over Bluetooth, so compare strings from the same mode). Nothing yet addresses the second."

**Evidence:** *Wireless browsing in 1.0* (what doesn't work; resume); *PTP/IP and join facts* (DeviceInfo rows); decision 6.

### 3.3 Performance budget table · measured values replace the guesses

Edit each row's target or notes as follows. Over USB the card's contents don't appear within the old targets in either mode.

- **Camera visible after connect.** *Current:* "≤ 2 s wired, ≤ 5 s Wi-Fi". *Proposed:* "Wi-Fi: the whole card is ready 2.0–3.0 s after the session opens and listing takes 4.7–8.3 s (397–555 handles; 8.4–9.1 s at 741); joining the camera's network separately takes 13.8–18.8 s from Start over Bluetooth (29.5 s in the one run that included the pairing). USB: 7–12 s in MSC (391–549 files), 65–123 s in MTP (391–825 files); the last-known card is shown at once." (Depends on decision 7, recommended; reword if Shamil decides otherwise.) *Evidence:* *Wireless browsing in 1.0*; *Wired import is viable*; *Listing time against card size*; the Bluetooth join tables.
- **First screen of thumbnails.** *Current:* "≤ 1 s after listing" (newest 60). *Proposed note:* "About 4.4 s over USB for 60 at 73.0 ms each (MTP, two in flight, 5 Nov; one run each; MSC was 188 ms one at a time on 1 Nov and isn't measured two at a time) and 2.1–2.3 s over the camera's Wi-Fi at 35–39 ms. The plan's 50 ms-per-thumbnail target (day 2) is met over the camera's Wi-Fi and not over USB. In MTP there is nothing to ask a thumbnail for until the catalogue ends. Target for 1.0: Shamil to set." *Evidence:* *Thumbnails over USB in MTP*; *Wireless browsing in 1.0*; decision 7. The home network took 48.1 ms each (one run).
- **Wired throughput, USB 2 iPhone.** *Current:* "≥ 30 MB/s" with the note "The bench iPhone; bus limit \~35 MB/s; 100 pairs in about 2.5 min". *Proposed:* "Holds for ARW (MSC 39.9 and 41.7 MB/s, MTP 38.2 and 39.1 MB/s, one at a time and two in flight) and fails for JPG in MTP (25.6 MB/s; MSC 41.7 MB/s). The 35 MB/s bus limit is wrong: the measured rates exceed it. Drop the 100-pair estimate or recompute it from these rates." Make the same correction in *Constraints*: "(about 35 MB/s bus ceiling)" becomes "(the measured rates reach about 42 MB/s)". *Evidence:* *Wired import is viable*; measurements table.
- **Wired throughput, USB 3 iPhone.** No change: still "Expected, not measurable on the bench".
- **Wi-Fi throughput, camera AP, 5 GHz.** *Current:* "≥ 8 MB/s". *Proposed note:* "Holds: 11.7–15.5 MB/s for 20 ARW, 12.6–17.4 MB/s over whole-card copies; the rate varies with where the phone is and other conditions, and single downloads ran at 5.4–6.1 MB/s in one run (5 Nov 01:09, cause unknown). The home network gave 10.18 MB/s (one run, app in front). Replace the 100-pair estimate or recompute it." *Evidence:* *Wireless browsing in 1.0*, including the 23:18 run's by-phase rates.
- **Memory and Energy rows** (from section 7, not section 4). The app's own probe peaked at 70–71 MB over USB and up to 113 MB over Wi-Fi, under the 150 MB budget. The Energy gauge isn't measured (a proposed drop, Part 2). *Evidence:* measurements tables; `ptpip.ap.download.memory.peak`.
- **Goal 1** ("Plug in or connect an α7C II and see its card contents within 5 seconds, newest first, with thumbnails."). *Proposed:* "See the card newest first: the last-known card at once, then the live listing, which takes 4.7–8.3 s over Wi-Fi once the card is ready (2.0–3.0 s after the session opens) and 7–12 s over USB in MSC (65–123 s in MTP), with thumbnails filling newest first." Wired doesn't meet 5 s in either mode; Shamil to set the target.
- **Goal 2** ("≥ 30 MB/s wired on the USB 2 bench iPhone (≥ 80 MB/s expected on USB 3 Pro models, unverified), ≥ 8 MB/s on the camera's 5 GHz access point."). *Proposed:* add "Met for ARW wired (38–42 MB/s) and on the camera's own network (11.7–15.5 MB/s); not met for JPG in MTP (25.6 MB/s); USB 3 unmeasured."
- **Goal 4** ("Keep transferring when the phone locks or the user switches apps, with progress visible in the Dynamic Island."). *Proposed:* "Over Wi-Fi, keep transferring when the phone locks or the person switches apps, inside a continued task (a whole card with about 329 s locked, one run; iOS can end the task, so the import pauses and continues). Over USB, `ImageCaptureCore` stops transfers 30 s after the app leaves the foreground, so a long wired import keeps the app in front, or pauses and continues on return (decision 1, recommended). Progress is visible in the Dynamic Island either way."

### 3.4 Background execution, strategy item 3 · depends on decision 1 (recommended; reword if Shamil decides otherwise)

**Current:** "the USB session survives suspension in practice, the PTP/IP session is re-established (the camera keeps the AP up for several minutes)"

**Proposed:** "over USB the session survives suspension (a 652 s lock, the longest tried), but `ImageCaptureCore` suspends transfers 30 s after the app leaves the foreground, in the background or under lock, even inside a continued task (MSC and MTP); a longer USB import keeps the app in front, or pauses and continues on return. Over Wi-Fi the session is lost when the app leaves the foreground outside a continued task and is reopened on return; inside one, a 360-file copy (15.25 GB) ran 983 s, 329 s of it locked, without expiring (one run; iOS also ended the task twice when the Camera app was opened). The camera keeps its Wi-Fi up while the phone stays joined (at least 13 minutes, 4 Nov, through background spells and a lock, with the Bluetooth link up). Once the phone left it started switching off about 50 s later in two runs of three, and was still up 59 s after the 5 Nov 01:13 leave."

**Evidence:** *Wired import is viable* (copy to Files); *ImageCaptureCore facts* (`ICDeviceBrowser`); *A phone that stays joined*; *How long an unused Wi-Fi stays up*; decisions 1, 2 and 4.

### 3.5 Permissions: Photos · depends on decision 9

**Current:** "The app requests `.addOnly` access so the permission sheet is the small one; `.readWrite` is requested only if the user turns on "Verify imports against Photos" (used to detect assets they deleted)."

**Proposed:** "The app requests read/write access once, at the first import, and works with Limited Access with nothing selected: add-only can save a photo but can't create the per-camera album without bringing up the read/write prompt anyway. The album is found by its stored identifier, and downloads are staged as complete-until-first-unlock so a save works while the phone is locked (shown with full access, K1; not yet tested with Limited Access). If the person chooses *Don't Allow* (not yet tested), the app imports to Files only and says so." Make the same change in three other places: the permissions table row "`NSPhotoLibraryAddUsageDescription`, `.addOnly`" with its text "Saves imported photos and videos to your library." (use the read/write usage string, and say that *Limit Access* with no photos selected is enough); "Add-only access level keeps the permission prompt minimal." in the frameworks table; and "add-only permission" in the Photos row of the Creators' App table. The Settings screen row's "verify against Photos" then needs no separate permission.

**Evidence:** *Photos albums* (A3, L2, K1, K2); decision 9.

### 3.6 Iteration 2 exit criterion

**Current:** "re-plugging after a pull resumes within 2 s."

**Proposed:** "after a replug the import carries on as soon as the card is listed again, and the interrupted file is copied again from its start." Nothing answers until the catalogue is done: 7–12 s in MSC, 65–123 s in MTP (391–825 files). An ARW restarts in about 1 s at 40 MB/s (decision 7, recommended).

**Evidence:** *Pass-through while ImageCaptureCore's catalogue runs*; *Wired import is viable*; cable pull at 11:56 (49 of 362 copied, the file in flight failed).

### 3.7 Iteration 4 exit criterion

**Current:** "Lock the phone during a 2 GB import and it finishes"

**Proposed:** "Over Wi-Fi, lock the phone during a 2 GB import and it finishes inside a continued task. Over USB the import pauses 30 s after the app leaves the foreground and continues when it returns; 2 GB takes about 50 s at 40 MB/s, so it can't finish locked." Wi-Fi hedge: a 360-file copy ran 983 s with 329 s locked and no expiry (one run), but iOS can end the task without warning (two expiries, both as the Camera app was opened), so the engine must pause and continue (decision 4, recommended).

**Evidence:** *Wireless browsing in 1.0* (whole-card copies); *Wired import is viable* (30 s limit).

### 3.8 Iteration 3 row and the roadmap · depends on decision 6; the Iteration 3/4 split is to be settled with the backlog

**Current (builds):** "`IPLink`: PTP/IP sessions on two sockets, SSDP discovery, typed-IP fallback; QR scan and `NEHotspotConfiguration` join flow; Local Network permission handling; camera pinning by serial."
**Current (exit):** "Same 100-file import over the camera's AP at ≥ 8 MB/s; discovery ≤ 5 s; survives AP drop and rejoin."

**Proposed builds:** "`IPLink`: Sony's whole-card PTP/IP session (SDIO_OpenSession, init sequence, contents-transfer mode) on two sockets, 0x9211 resume, passive SSDP listening with a typed-IP fallback; the Bluetooth hand-off (one in-app pairing, Wi-Fi switched on, details read, `NEHotspotConfiguration` join confirmed by the camera's gateway) in place of the QR scan; Local Network permission handling; camera pinning by serial; recovery from a dropped card or Wi-Fi, pause and continue; the home network if decision 5 keeps it." Spike-remaining.md, section 6 also wants the continued task and Live Activity for Wi-Fi and the proximity reminder in the Iteration 3 and 4 sections or files. The proposal keeps them in Iteration 4; [iteration-3-4-backlog.md](iteration-3-4-backlog.md) (draft, 7 Nov, sections 0, 9 and 13) proposes that the second engineer builds the continued-task wrapper and the Live Activity in the first week for Shamil's Wi-Fi path to use, with the proximity reminder, the Lock Screen widget and the polish staying in Iteration 4. The split is Shamil's to settle on 13 Nov; if it is taken, add "the continued task and the Live Activity's paused state for Wi-Fi" to the Iteration 3 builds above.
**Proposed exit** (the same text goes in iteration-3-4-backlog.md, section 9): "Same 100-file import over the camera's AP at ≥ 8 MB/s with the phone near the camera; on the camera's own network no discovery is needed (192.168.122.1), and the camera answers within [target, Shamil to set; measured 13.8–18.8 s after *Start* once paired]; on the home network the camera is found by listening; the import survives a dropped card or Wi-Fi with the app in front (the 4 Nov 01:08 recovery, 97 s, one run) and, with the app away, pauses and notifies until a join can be made." The 5 s discovery target isn't shown: 4.65 s was inside a 5 s listen and the announcement interval isn't measured.

**Evidence:** *SSDP discovery*; *Wireless browsing in 1.0* (recovery 97 s, 4 Nov, one run, app in front); *PTP/IP and join facts*; decisions 5 and 6.

**Roadmap, "After 1.0".** **Current:** "1.1 is Bluetooth wake and credential hand-off plus the differential check on BLE wake, to close the one-tap-connect gap with Creators' App". **Proposed (if decision 6 is taken):** "1.1 is the differential check on BLE wake, to close the one-tap-connect gap with Creators' App; the Bluetooth Wi-Fi switch-on and credential hand-off move into Iteration 3." Open for Shamil: spike-remaining.md lists "Bluetooth wake" as out of scope for 1.0 without saying what is left of it once the Wi-Fi switch-on moves, so say whether "Bluetooth wake" stays in 1.1.

### 3.9 Wi-Fi join flow (UX section) · depends on decision 6

**Current:** "The user sets the camera to its Wi-Fi access-point mode; the app shows the camera's screen instruction, scans the QR code the camera displays (SSID and password are encoded in Sony's `W01:` QR format) with `DataScannerViewController`, calls `NEHotspotConfigurationManager` to join, and starts SSDP discovery. A typed IP is the escape hatch."

**Proposed (if decision 6 is taken):** "The app asks the person to open the camera's Bluetooth *Pairing* screen once (MENU › Network › Bluetooth › Pairing), then to accept iOS's pairing request and the camera's confirmation. After that it connects over Bluetooth, switches the camera's Wi-Fi on, reads the network name and password and calls `NEHotspotConfigurationManager` to join (one iOS prompt), confirming the join by the camera's gateway, 192.168.122.1, and retrying if it doesn't come; on the camera's own network no discovery is needed (the camera is at 192.168.122.1). A typed IP is the escape hatch." If decision 6 is not taken: the person switches PC Remote Function on and joins in Settings, as on 2 Nov. No QR code was seen in either case, so either way remove the permissions-table row "Scan the camera's QR code" (`NSCameraUsageDescription`, "Only when the user taps "Scan code"").

**Evidence:** *Day-6 mode matrix* (joined in Settings, no QR code in PC Remote) and the note under *Wireless browsing in 1.0* (Smartphone Connect showed no QR code, 2 Nov); the Bluetooth join runs in *BLE advertisement* (the camera's gateway on the Wi-Fi path 9.5–10.6 s after the join call, `ptpip.ap.join`; joins took 7.4–10.6 s with the prompt); *Without Creators' App's pairing*. The *PTP/IP and join facts* QR-code and join-flow rows are still to update (spike-remaining.md, section 4).

### 3.10 Risks and open questions · tick, answer, retire, add

**Open questions to tick:**
- *Current:* "- [ ] Unknown as of 31 Oct 2026 — the spike must answer it: which α7C II USB connection mode gives `ImageCaptureCore` a session: *Still Img Transfer (MTP)* alone, or also *Select on Connect*?" *Proposed:* "[x] Answered 1 Nov: *Image Transfer (MTP)* and *Image Transfer (MSC)* both give a session that lists the card (chosen at the camera's *Select USB Connect Mode* prompt, and the mode can be fixed). *Remote Shoot (PC Remote)* opens a session but `ImageCaptureCore` lists no files in it (4 Nov); *Live Stream (USB Streaming)* doesn't enumerate."
- *Current:* "- [ ] Is the PTP/IP initiator GUID remembered across camera power cycles, or does every connection need re-pairing on the camera?" *Proposed:* "[x] Answered 2 Nov: no pairing is needed in *PC Remote* on the camera's own network. The same GUID reconnected after a power cycle with no prompt, and a new GUID connected with no prompt either, so the camera's Wi-Fi password is the only gate."
- *Current:* "- [ ] Does the camera emit `ObjectAdded` over USB while in MTP mode, or only in PC Remote mode?" *Proposed:* "[x] Answered: not in MTP (not advertised). In *Remote Shoot (PC Remote)* it is advertised, but none arrived on a plain `ImageCaptureCore` session (4 Nov 12:10; Sony's init sequence over USB is untried). Over Wi-Fi in PC Remote it does: Sony's 0xC201 (2 Nov)."
- *Current:* "- [ ] Real throughput figures on the base-model (USB 2) bench iPhone with a UHS-II card in the camera; USB 3 figures wait for a borrowed Pro model." *Proposed:* tick once Shamil records the card type; the figures are in *Wired import is viable* (ARW 38–42 MB/s, JPG 25.6 MB/s in MTP and 41.7 in MSC); USB 3 is unmeasured.

**Risks to retire** (mark retired with the result):
- "α7C II does not expose the card over PTP/IP to a phone-class initiator (only in PC Remote mode, or only tethered captures)". *Result:* retired; *PC Remote* lists the whole card through Sony's whole-card session (see "Where we use Sony's own protocol, and why").
- "`ImageCaptureCore` on iOS rejects `GetPartialObject` pass-through or caps throughput well below the bus". *Result:* retired; 0x101B passes through in MTP (37.29 MB/s, resume verified), and throughput is 38–42 MB/s for ARW.
- "The α7C II does not advertise a filterable BLE service UUID while powered off". *Result:* retired; it advertises UUID 1800 on, asleep and off.

**Risks to add** (likelihood and impact for Shamil to rate):
- Sony-specific pieces (whole-card session, 0x9211, the Bluetooth hand-off) were reverse-engineered and may break on a firmware change or draw an App Store objection. *Mitigation:* read the operation list from DeviceInfo, keep the code in one place, fixtures per firmware; the review cost is unaddressed (decision 6).
- `ImageCaptureCore` suspends transfers 30 s after the app leaves the foreground, so a long USB import needs the app in front. *Mitigation:* stay in front with the screen on; pause on *did suspend*, continue on return (decision 1).
- The camera sometimes drops its card and Wi-Fi, most likely with Creators' App open in the background (not proven). *Mitigation:* the copy recovered from a camera restart in 97 s (one run, app in front; the drop looks the same in the log, but recovery from a drop with Creators' App open is untested); decisions 3 and 4.

### 3.11 Multicast entitlement wording · Shamil's choice, submit or skip

**Current:** "The multicast entitlement must be approved before the first TestFlight external build; apply in the spike week." Also in the key-dates table: "entitlement request submitted the same day" (spike start) and "multicast entitlement ideally granted" (internal TestFlight), and in the permissions table "(granted on request via Apple's form)".

**Proposed, if skipped (A):** "SSDP discovery listens passively, which worked without the multicast entitlement on the camera's own network (0.73 s) and on the home network (1.91 s and 4.65 s into 5 s listens); how often the camera announces isn't measured. Active M-SEARCH didn't go out without the entitlement (ours stayed pending, and the camera ignores a unicast one; whether it answers a multicast search is unknown), so it isn't part of 1.0. A typed address is the fallback." Drop the key-date wording, park the draft request, remove the permissions-table row "SSDP multicast", and change "it needs three entitlements, one of which (multicast) requires a request to Apple" to say two entitlements and no request.
**Proposed, if submitted (B):** the same text, ending: "The entitlement request keeps active search open; it is not required for any build, and passive listening works without it. Submitted: [date, reference to fill]." Change the key-date cells to "requested; passive listening needs no entitlement". Keep the permissions-table row "SSDP multicast" and change "(granted on request via Apple's form)" to "(requested; passive listening needs none)".

**Evidence:** *SSDP discovery*; *Multicast entitlement* (the findings' table is blank: submission and status aren't recorded); spike-remaining.md, section 4.

### 3.12 Proximity reminder section · decision 8 (not listed in section 4)

**Current:** "debounces to one reminder per camera per 30 minutes" and "stops when Bluetooth is off or Low Power Mode is on" (and "we match the camera's advertised service UUID and never read Sony's characteristics in 1.0", in the frameworks table).

**Proposed additions to "How it works in 1.0":**
- "1800 is Bluetooth's generic Generic Access service, so after a wake the app confirms the camera by the peripheral identifier stored when it was linked, or by Sony's company ID together with the name."
- "The trigger is the camera coming into range: the advertisement is identical on, asleep and off, so the reminder says 'nearby', not 'switched on'."
- "Use Core Bluetooth state restoration. iOS relaunched a killed app in the background with the phone locked and handed back the scan (5 Nov; the app killed itself). An app the person swipes away isn't relaunched, per Apple (untested), so reminders stop until the app is next opened."
- "Restart the scan from a wake, not a timer, and when Bluetooth comes back on."
- "Hold reminders while connected or importing, over USB too (the camera advertises while our app is connected), and hold further reminders for a long time after one: with a 60 s debounce iOS reported a camera that came and went 137 times in 10 hours and 38 reminders got through (4–5 Nov). One reminder per arrival; the hold length is Shamil's to set."
- "Ask for notification permission when the person switches the reminder on (the first reminder failed with it undetermined)."
- Constraints: Low Power Mode didn't stop background discovery in either run that had it on (3 Nov 00:08, and 4 Nov 14:31 to 5 Nov 00:58, with Low Power Mode on at every scan restart from 14:54 to 00:24), contrary to the app's warning text; say "may stop" until it is tested on purpose. Replace "never read Sony's characteristics in 1.0" with the 3.1 wording if decision 6 is taken, and the sentence "Because 1.0 reads no Sony characteristic, a firmware change can break detection only by changing the advertised UUID." with: "Detection reads no characteristic, so a firmware change breaks it only by changing the advertised UUID; the Wi-Fi hand-off, which reads and writes Sony's characteristics, is separate."
- The 1.1 paragraph's "Bringing the camera's Wi-Fi up over Bluetooth is Sony's proprietary handshake and remains the 1.1 reverse-engineering item" changes with decision 6 (3.8).
- Step 1 (*Link*): "scans for the Sony camera service UUID (recorded on spike day 6)" becomes "scans for service 1800 (Generic Access, the only service UUID the camera advertises; recorded 2 Nov)".
- *Constraints*: "If the α7C II does not advertise while powered off (Sony's *Remote Power ON/OFF* setting is meant to keep the radio up; the spike confirms), detection works only while the camera is on." becomes "The α7C II advertises on, asleep and off (Creators' App quit, with *Bluetooth Function* on and, as far as recorded, *Remote Power ON/OFF* on), so detection doesn't depend on the camera being on." Whether *Remote Power ON/OFF* was on is still to confirm (spike-remaining.md, section 3).

**Evidence:** *Proximity reminder in 1.0* (every bullet above); decision 8; *Background discovery worked with Low Power Mode on*.

### 3.13 "Assumption to confirm in the spike" (not listed in section 4)

**Current:** "**Assumption to confirm in the spike:** the α7C II exposes the memory card's object store over PTP/IP when connected to a phone over Wi-Fi, not only images captured during a tethered session. If it does not, wireless import in 1.0 falls back to the camera's *Send to Smartphone* flow (camera-side selection) and full browsing stays wired-only."

**Proposed:** "**Confirmed in the spike (2 Nov):** in *PC Remote* the α7C II lists its whole card over PTP/IP once the session is opened with Sony's whole-card contents transfer; a plain session gets StoreNotAvailable. The *Send to Smartphone* fallback is not needed (dropped 3 Nov)."

**Evidence:** *Wireless browsing in 1.0*.

### 3.14 Summary and USB row (not listed in section 4) · decisions 6 and 7

- **Summary, "technical bet".** *Current:* "rather than reverse-engineering Sony's proprietary phone protocol". *Proposed (if decision 6 is taken):* "wherever the camera supports them, and use Sony's own operations only where the α7C II needs them (listing and resuming over Wi-Fi, the Bluetooth hand-off), kept in one place (see "Where we use Sony's own protocol, and why")." Change the next sentence as well: "That keeps the app App Store-safe, testable without a camera (a PTP simulator), and extensible…" becomes "That keeps the app testable without a camera (a PTP simulator) and extensible to any PTP-speaking body later; the App Store review cost of the Sony-specific parts is still unaddressed (see "Risks and open questions")."
- **Transports table, USB row.** *Current:* "`Setup → USB → USB Connection Mode = Still Img Transfer (MTP)`". *Proposed (if decision 7 is taken):* "USB connection mode *Image Transfer (MSC)* (recommended in the app's copy) or *Image Transfer (MTP)*; *Remote Shoot (PC Remote)* lists no files over USB." The menu path is the plan's and its wording isn't yet recorded (findings, menu wording table), so quote the mode names until Shamil reads the path off the camera. Make the same change in 'What we are matching' ("`USB Connection Mode → Still Img Transfer (MTP)`, which is also what the built-in Photos app uses").

**Evidence:** *Open questions from the proposal* (USB mode row); *Wired import is viable* (MSC against MTP; PC Remote lists no files); *Wireless browsing in 1.0* (Sony's whole-card session, 0x9211); decisions 6 and 7.

### 3.15 Wi-Fi join flow, "first-class" sentence (not listed in section 4) · decision 5

**Current:** "Both setups are first-class: discovery, pairing and the hardware test plan cover each equally."

**Proposed (if decision 5 is taken as recommended):** "The camera's own network over Bluetooth is the 1.0 route. A shared LAN is supported when the camera is already on it, after a one-time setup on the camera (join the home Wi-Fi, *PC Remote Cnct Method* *Wi-Fi Access Point*, access authentication off), and the app waits at least 40 s for the first handshake (one run, 4 Nov)." What turning access authentication off costs in security is to be checked before 1.0 asks anyone to do it.

**Evidence:** *PC Remote over the home network*; decision 5.

### 3.16 Roadmap gate wording (spike-plan.md, day 10; not listed in section 4)

**Current:** "Each gate is a decision point: the go/no-go after the spike decides whether wireless stays in 1.0 or moves to 1.1."

**Proposed:** "Go/no-go on 13 Nov 2026: wireless stays in 1.0 (Shamil's 2 Nov decision); the wired, byte-range resume, wireless, SSDP, transfer-while-shooting and proximity rows are recorded in the findings with their numbers. [Shamil to confirm after Part 1.]"

**Evidence:** spike-remaining.md, *Decisions (Shamil, 2 Nov)*; the six go/no-go sections of the findings; spike-plan.md, day 10 ('Decision recorded in the proposal with the numbers behind it').

### 3.17 Photos' own Import: what 1.0's wired import adds · a new risk row (positioning is Shamil's)

**What the findings show:** on 5 Nov (MTP) Photos › Import listed the whole card: 539 items, 28.5 GB, 105 marked *Already Imported*, RAW+JPEG pairs as one item (Shamil's screenshots). Many tiles were a grey placeholder rather than a picture (whether they filled in later wasn't checked), and it was shown once, a few minutes after the spike had listed the card on the same plug-in, with the spike's session still open, so whether Photos lists the card on a fresh plug-in with no other app's session open isn't tested. No import was recorded. On 1 Nov it listed nothing, cause unknown. Nothing in the spike compared Photos' import with ours beyond the listing.

**Proposed new risk row:** "Photos' own Import already lists this camera's whole card over USB, so wired import alone isn't the whole case for the app. *Mitigation:* state what 1.0 adds. Draft, for Shamil to complete and strike what Photos turns out to do: import over Wi-Fi with the Bluetooth hand-off; the proximity reminder; pause and continue with progress outside the app; albums per camera or per import and the RAW or JPEG original as the user's choice; [anything Shamil has found in Photos' own flow]. None of this was compared with Photos in the spike." Add a matching sentence to the Summary once worded.

**Evidence:** *ImageCaptureCore facts* (first row, Photos); spike-remaining.md, section 4 (*Risks and open questions*) and section 7 ("Now unnecessary": it isn't our app's path).

### 3.18 Key dates, "Second engineer starts" (spike-remaining.md, section 6; not listed in section 4)

**Current:** "Onboarding pack: this doc, the spike findings, the Iteration 1 codebase"

**Proposed:** "Onboarding pack: this doc, the spike findings, the Iterations 3 and 4 backlog (including its plain-terms guide to the Sony-specific pieces), the Iteration 1 codebase"

**Evidence:** spike-remaining.md, section 6, item 3 ("The second engineer starts 18 Jan and needs these in the onboarding pack"); [iteration-3-4-backlog.md](iteration-3-4-backlog.md).
