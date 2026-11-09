# Iterations 3 and 4 bench run: wireless, background and proximity

Bench run after W16 (the switch-on, #110) · Shamil · Plan: the wireless plan's section 4, with the acceptance criteria in [iteration-3-4-backlog.md](iteration-3-4-backlog.md) · Findings it builds on: [spike-findings.md](spike-findings.md)

Results checklist, filled on the bench iPhone with the α7C II. Every value comes from the camera, the phone or the log; nothing is filled in ahead of the measurement. A row stays empty until it has been run, and a failed check is recorded as *Fail* with what was seen, never left out. The app writes coarse lines to the unified log (read them in Console: subsystem `net.shamil.shutter-bridge`, category `browse`); see *What the log holds* below for the line each record comes from. The **Record** column names what to copy, from the screen, a stopwatch or Console. Never record a Wi-Fi name or password, the camera's serial or hardware ID, a device or peripheral identifier, or a home address here (the app's log already leaves them out).

## Setup

| Item | Value |
| --- | --- |
| iPhone model and iOS build | _to fill_ |
| Product app build (from TestFlight, with the W16 switch-on) | _to fill_ |
| Camera model and firmware | _to fill_ |
| Card (type, number of files by kind) | _to fill_ |
| Camera setting for the route: *PC Remote Function* off, *Bluetooth Function* on, *Bluetooth Rmt Ctrl* (on or off, as set) | _to fill_ |
| Hotspot Configuration ticked on the App ID, and the build signed with it (the TestFlight workflow checks the second) | _to fill_ |
| Other apps holding a Bluetooth link to the camera (Creators' App open, quit, or not installed) | _to fill_ |
| Phone's Low Power Mode and Background App Refresh settings | _to fill_ |

## What the log holds

The product app has no `SpikeLog`. Its `OSLogBenchLog` writes lines for the import (continued task started, ended, paused, notification posted, each file imported, job ended), Wi-Fi recovery steps, the proximity scan (with the RSSI of each report) and the reminder. Since W20 it also writes the Wi-Fi route's own lines: `CameraTransport` records them as values (`TransportTrace`) and the app writes each as one line (`TransportTraceWording`). They start `wifi join:` (the session and the Bluetooth hand-off) or `wifi link:` (the camera's session over Wi-Fi). Times are seconds to a tenth since the step the line names; sizes are in MiB with the bytes. No line holds a network name, password, serial, peripheral or device identifier, GUID or address, except the camera's fixed gateway 192.168.122.1.

Filter Console on `wifi join` or `wifi link` to see only these. The lines each check needs (`…` is a number):

| Check | What to read | Line to look for |
| --- | --- | --- |
| 3 | The step times of one run | `wifi join: ready after … s (hand-off … s, join … s, session … s)`. *Hand-off* is Bluetooth: the connect, the hand-off and any rewrite. *Join* runs from the network's details to the camera's gateway, with iOS's prompt. *Session* runs from the gateway to the camera's session being open, with the port, PTP/IP and the card's listing poll. |
| 3 | The Bluetooth connect | `wifi join: Bluetooth connected in … s` |
| 3 | Status 2 | `wifi join: CC09 Wi-Fi status 2 (on) at … s into the hand-off`. The CC09, CC08 and network details lines count from the hand-off run, which starts after the Bluetooth connect and starts again at 0 after a reconnect and on each rewrite. The RSSI lines and `hand-off done in` count from before the connect, so they read about the connect's time more. The RSSI is read on the same Bluetooth link as the hand-off starts (new with W20): compare one run's `CC08 written (Wi-Fi on) at … s` and the time from it to status 2 with the spike's (CC08 to status 2 in 2.3 to 2.5 s, [spike-findings.md](spike-findings.md)). If the hand-off is clearly slower, say so: the first RSSI read can come off the hand-off's start. |
| 3 | The join and the gateway | `wifi join: join 1 returned after … s (iOS's prompt included)`, then `wifi join: the camera's gateway 192.168.122.1 appeared … s after the join` |
| 3 | The port | `wifi link: the camera answered on its port … s after the open began (fresh)` |
| 3 | The card ready | `wifi link: card ready … s after the open began, … poll(s), listed … s after the first poll (fresh)` |
| 3 | The RSSI during the hand-off | `wifi join: Bluetooth RSSI … dBm, … s into the Bluetooth step (connect included)`. There are two per hand-off: one as the hand-off starts, after the connect, and one as the network's details come in. Their times count from before the connect, like `hand-off done in … s (connect included)`, not from the hand-off run like the CC09 lines. The RSSI is read beside the hand-off and never holds it up. It reads `not available` when iOS gives none. |
| 5 | The poll count inside the stay | `wifi join: preparing an import on the camera's Wi-Fi, without a join`, then `wifi link: card ready … s after the open began, 1 poll, … (reopening)`. *1 poll* means the card was ready at the first poll. |
| 7 | The CC09 status after the slow prompt | `wifi join: join 1 returned after … s`, then `wifi join: after the join, CC09 Wi-Fi status 3 (stopping)` (or `0 (off)`) `; the camera's 50 s have passed; its Wi-Fi is off, so switching it on again` |
| 7 | The CC08 rewrite | `wifi join: rewriting CC08, rewrite 1 of 2`, then the rewrite's own `wifi join: CC09 Wi-Fi status … at … s into the hand-off` lines (the sequence with times), `wifi join: CC08 written (Wi-Fi on) at … s into the hand-off` and `wifi join: rewrite hand-off done in … s (connect included)`. The CC09 and CC08 times start again at 0 for the rewrite. The seconds from the rewrite to the join are the next `wifi join: join … returned after` and its gateway line. A link that had to reconnect shows `wifi join: the Bluetooth link dropped during the hand-off …; connecting again (reconnect 1)`. |
| 8 | The 0x9211 resume | `wifi link: resuming a file with 0x9211 from … MiB (… B) of … MiB`, then `wifi link: the resumed file finished after … 0x9211 reads`. A refused first read shows `wifi link: the camera refused the first 0x9211 read at …; copying the file again from the start`. |
| 9 | The keep-alive spacing | `wifi link: keep-alive … answered, … s after the last command, … s after the previous keep-alive`. Keep-alives go out only while the session is idle, so none show while a file is copying. |
| 9 | The GetDevicePropValue count (expected 0) | `wifi link: closed: … GetDevicePropValue sent 0; …`, written when the link closes (after the import, or when a reconnect replaces it). |
| 9 | The offset resumed from | `wifi link: the session was lost: …` (usually `the network went away` or `no answer in time`), then after the reconnect `wifi link: resuming a file with 0x9211 from … MiB (… B) of … MiB`. The plan expects the 16 MiB checkpoint (16777216 B, or a multiple of it). |
| 10 | The recovery's step times | The same `wifi join:` lines as check 3, after `wifi recovery:`. `wifi join: reopening on the camera's Wi-Fi gave up after … s; going back to Bluetooth` marks the end of the Wi-Fi retry. The retry is counted in *session*, so subtract its `gave up after … s` from *session* in the `wifi join: ready after` line to get the reopened session's own time. |

The other `wifi join:` and `wifi link:` lines give more detail: each preparation's start, failed joins with their reason, port tries, and rejoining with the app away. Check 6's CC09 status after the leave isn't in the log: the app has closed its Bluetooth link by then, so watch the camera's Wi-Fi icon instead.

## Wording to read off the camera

Placeholders in the app until these are read off the camera (B:144). Nothing else in the app waits on them.

| What | Where the app has it | Camera's wording | Result |
| --- | --- | --- | --- |
| Menu path to the Bluetooth pairing screen | `OnboardingWording.cameraPath`, `unverified` | _to fill_ | |
| Names of the two settings to check (*Bluetooth Function*, *Bluetooth Rmt Ctrl*) | `OnboardingWording.settingsToCheck`, `unverified` | _to fill_ | |
| The camera's pairing confirmation (and whether it shows a code) | `OnboardingWording.cameraConfirmationWording`, `nil` until set | _to fill_ | |
| Which Settings switch governs a USB camera's access (what to do if ImageCaptureCore refuses) | `CamerasWording.notAllowedTitle` and its copy, `unverified`; the copy names the Camera setting | _to fill_ | |

## The quick run

Eleven checks, from the plan's section 4. The *Pass if* column is the plan's line; *Record* is what to copy into the result.

| # | Check | Pass if | Record | Result |
| --- | --- | --- | --- | --- |
| 1 | **Onboarding from unpaired.** Start with the pairing removed in iOS's Bluetooth settings and the camera's *Pairing* screen open. Remove the app's camera by deleting and reinstalling the app (it has no way to remove one). | Both prompts appear (iOS's pairing request, then the camera's confirmation); the peripheral identifier is stored; a reconnect makes no prompt. The unpaired error path sends the person to *Pair Your Camera*, with no loop. | Seconds from the first read to the pairing result (the read has no timeout); whether each prompt appeared; the reconnect's time; what the unpaired path showed and how many times. | |
| 2 | **First Local Network run.** First connection after a fresh install, or with Local Network switched off for the app in Settings. | The explanation shows first, then a waiting state, never a failure. | The order of screens; seconds from *Continue* to the connection answering after the prompt was allowed. | |
| 3 | **Start to camera answering,** about 10 runs: camera idle, paired, the join prompt accepted at once. Start is tapping the camera in *Cameras* (the app has no *Start* button), then *Import*. | At most 25 s from tapping the camera to the camera answering, in each run. | Per run: total seconds by stopwatch. Slowest run, median. The step times from `wifi join: ready after … s (hand-off … s, join … s, session … s)`, with the Bluetooth connect, status 2, join, port and card-ready lines (see *What the log holds*). The Bluetooth RSSI from the two `wifi join: Bluetooth RSSI … dBm` lines. | |
| 4 | **The same 100-file import** near the camera. Files already imported can't be selected (matched by name, capture time and size on either link), so reinstall the app first (that empties the catalogue and means pairing again), or use 100 files not yet imported with the same mix. Select them in *Browse* and tap *Import*. Keep the USB copies elsewhere for the comparison. | At least 8 MB/s; memory stays under 150 MB. | The 100 files' size and the MB/s overall and for the slowest stretch; peak memory; whether any file was retried. | |
| 5 | **A second import inside the stay.** | No join prompt; the card is ready at the first poll. | Whether a prompt appeared; seconds to the card ready, by stopwatch; the stay's countdown at the start. The poll count from `wifi link: card ready … s after the open began, … poll(s) … (reopening)`. | |
| 6 | **Stay and leave.** (a) Let the 3-minute stay run out in front. (b) Go to the background after an import. (c) Read the copy. | (a) The app leaves the camera's network in front when the stay ends. (b) It leaves at once, with the background time iOS gives: the hotspot configuration is gone (the week-1 removal test). (c) The copy says the camera's Wi-Fi may stay on. | (a) Seconds from the end of the import to the leave. (b) Whether the configuration was removed, how long it took, and the phone's network afterwards; if it failed, the stay rule goes back to Shamil (option (b) of the decision pack's recommendation 1). (c) The camera's CC09 status after the leave and when it went to 3 and 0. | |
| 7 | **A slow join prompt** (leave iOS's prompt up for over 50 s). | CC09 goes to 3 or 0, then CC08 is rewritten, and the join succeeds. | Seconds the prompt stayed up (`wifi join: join 1 returned after … s`); whether the camera's Wi-Fi stayed on or switched off, and whether the join succeeded. From the log: the status seen after the prompt (`wifi join: after the join, CC09 Wi-Fi status …`), the rewrite (`wifi join: rewriting CC08, rewrite 1 of 2`), the CC09 status sequence with times, whether Bluetooth had to reconnect, and the seconds from the rewrite to the join. The app never writes CC08 while the status reads 2, so whether a second write then restarts the camera's 50 s count stays unknown. Record it as *Inconclusive*. | |
| 8 | **Lock during a 2 GB import.** Then force an expiry by opening the Camera app. | The import finishes inside the continued task. After the forced expiry: the pause notification, *Continue*, every file once, the file in flight resumed (0x9211), and the SHA-256 matching. | Task length and whether it expired unforced; seconds from expiry to the notification; seconds from *Continue* to bytes moving; the count of files copied twice (expected 0); the in-flight file's SHA-256 against the first session's. The 0x9211 resume and the in-flight file's offset from `wifi link: resuming a file with 0x9211 from … MiB (… B) of … MiB` and `wifi link: the resumed file finished after … 0x9211 reads`. | |
| 9 | **Turn Wi-Fi off, or walk away, mid-file.** | It reconnects and resumes at the 16 MiB checkpoint. The log shows no `GetDevicePropValue` and keep-alives every 10 s. | Which of the two was done; seconds to reconnect, by stopwatch; whether the files came out whole and none repeated. From the log: the offset resumed from (`wifi link: resuming a file with 0x9211 from …`), the keep-alive spacing (`wifi link: keep-alive … answered, … s after the last command, … s after the previous keep-alive`), and the `GetDevicePropValue` count (`wifi link: closed: … GetDevicePropValue sent 0; …`, expected 0). | |
| 10 | **The camera drops its card or switches Wi-Fi off.** (a) With the app in front. (b) With the app away. | (a) It recovers well under 97 s, with no 30 s rejoin wait. (b) It pauses with *Paused: open Shutter Bridge to join the camera's Wi-Fi, then the import carries on.* and posts *Import paused. Open Shutter Bridge to continue.* | (a) Seconds from the failure to the next file starting, with the step times (wait, Bluetooth, status 2, join, session) from the `wifi join:` lines; whether the wait before Bluetooth (decided, Shamil, 9 Nov: 30 s) was too long or too short. (b) The pause line shown (exact words) and whether the notification came (exact words); whether a Bluetooth switch-on from the background worked. | |
| 11 | **Proximity.** (a) Locked phone, camera brought into range. (b) During a USB or Wi-Fi import. (c) The 4-hour hold across a relaunch. (d) After a SIGKILL: stop the app from Xcode (Stop, or `kill -9`) with the camera out of range, and don't swipe it away (iOS doesn't relaunch a swiped-away app for Core Bluetooth). | (a) The reminder appears. (b) No reminder during a USB or Wi-Fi import. (c) The hold survives a relaunch. (d) iOS hands back the scan through `willRestoreState`. | (a) Seconds from coming into range to the reminder; RSSI; whether it needed the app-refresh task (the 30-minute re-arm is `unverified`) or a wake. (b) Reminders seen. (c) Whether a second arrival inside 4 hours reminded; what the quiet-gap comparison in the log shows. (d) Seconds from the relaunch to the report. | |

## Left from this run

To fill after the run: what failed, what was inconclusive, and which `unverified` constants a measurement now backs (each is marked in the code, listed in the backlog's status notes).

| Item | What was seen | Next step |
| --- | --- | --- |
| _to fill_ | | |
