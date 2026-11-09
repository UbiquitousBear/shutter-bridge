# Iterations 3 and 4 bench run: wireless, background and proximity

Bench run after W16 (the switch-on, #110) · Shamil · Plan: the wireless plan's section 4, with the acceptance criteria in [iteration-3-4-backlog.md](iteration-3-4-backlog.md) · Findings it builds on: [spike-findings.md](spike-findings.md)

Results checklist, filled on the bench iPhone with the α7C II. Every value comes from the camera, the phone or the log; nothing is filled in ahead of the measurement. A row stays empty until it has been run, and a failed check is recorded as *Fail* with what was seen, never left out. The app writes coarse lines to the unified log (read them in Console: subsystem `net.shamil.shutter-bridge`, category `browse`); see *What the log holds* below for what is and isn't there. The **Record** column names what to copy, from the screen, a stopwatch or Console. Never record a Wi-Fi name or password, the camera's serial or hardware ID, a device or peripheral identifier, or a home address here (the app's log already leaves them out).

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

The product app has no `SpikeLog`. Its `OSLogBenchLog` writes lines for the import (continued task started, ended, paused, notification posted, each file imported, job ended), Wi-Fi recovery steps, the proximity scan (with the RSSI of each report) and the reminder. `CameraTransport` writes nothing itself: `IPLink.diagnostics` (polls, keep-alives answered, resumes, steps, ignored events) is never logged, and the hand-off's CC09 and CC08 events, its step times and the RSSI during it aren't either. So these records are **blocked** until the app logs them (the diagnostics at session close; the hand-off and `WirelessSession` phase changes, with times and no identifiers): check 3's step times and RSSI, check 5's poll count, check 7's CC09 sequence and rewrite, check 8's 0x9211, and check 9's keep-alive spacing, `GetDevicePropValue` count and resume offset. Record what can be seen (stopwatch, screen lines, Console) and write *blocked: not logged* for the rest; a Pass needs the measurement, so those checks stay *Inconclusive* on the blocked part.

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
| 3 | **Start to camera answering,** about 10 runs: camera idle, paired, the join prompt accepted at once. Start is tapping the camera in *Cameras* (the app has no *Start* button), then *Import*. | At most 25 s from tapping the camera to the camera answering, in each run. | Per run: total seconds by stopwatch. Slowest run, median. The step times (Bluetooth connect, status 2, join, session open) and the Bluetooth RSSI are *blocked: not logged*. | |
| 4 | **The same 100-file import** near the camera. Files already imported can't be selected (matched by name, capture time and size on either link), so reinstall the app first (that empties the catalogue and means pairing again), or use 100 files not yet imported with the same mix. Select them in *Browse* and tap *Import*. Keep the USB copies elsewhere for the comparison. | At least 8 MB/s; memory stays under 150 MB. | The 100 files' size and the MB/s overall and for the slowest stretch; peak memory; whether any file was retried. | |
| 5 | **A second import inside the stay.** | No join prompt; the card is ready at the first poll. | Whether a prompt appeared; seconds to the card ready, by stopwatch; the stay's countdown at the start. The poll count is *blocked: not logged*. | |
| 6 | **Stay and leave.** (a) Let the 3-minute stay run out in front. (b) Go to the background after an import. (c) Read the copy. | (a) The app leaves the camera's network in front when the stay ends. (b) It leaves at once, with the background time iOS gives: the hotspot configuration is gone (the week-1 removal test). (c) The copy says the camera's Wi-Fi may stay on. | (a) Seconds from the end of the import to the leave. (b) Whether the configuration was removed, how long it took, and the phone's network afterwards; if it failed, the stay rule goes back to Shamil (option (b) of the decision pack's recommendation 1). (c) The camera's CC09 status after the leave and when it went to 3 and 0. | |
| 7 | **A slow join prompt** (leave iOS's prompt up for over 50 s). | CC09 goes to 3 or 0, then CC08 is rewritten, and the join succeeds. | Seconds the prompt stayed up; whether the camera's Wi-Fi stayed on or switched off, and whether the join succeeded; *blocked: not logged*: the CC09 status sequence with times, whether Bluetooth had to reconnect, the seconds from the rewrite to the join, and whether a second write while the status was 2 restarted the camera's 50 s count. | |
| 8 | **Lock during a 2 GB import.** Then force an expiry by opening the Camera app. | The import finishes inside the continued task. After the forced expiry: the pause notification, *Continue*, every file once, the file in flight resumed (0x9211, once the app logs it), and the SHA-256 matching. | Task length and whether it expired unforced; seconds from expiry to the notification; seconds from *Continue* to bytes moving; the count of files copied twice (expected 0); the in-flight file's SHA-256 against the first session's. *Blocked: not logged*: 0x9211 and the in-flight file's offset on resume. | |
| 9 | **Turn Wi-Fi off, or walk away, mid-file.** | It reconnects and resumes at the 16 MiB checkpoint. Once the app logs its diagnostics, the log shows no `GetDevicePropValue` and keep-alives every 10 s. | Which of the two was done; seconds to reconnect, by stopwatch; whether the files came out whole and none repeated. *Blocked: not logged*: the offset resumed from, the keep-alive spacing and the count of `GetDevicePropValue` (expected 0). | |
| 10 | **The camera drops its card or switches Wi-Fi off.** (a) With the app in front. (b) With the app away. | (a) It recovers well under 97 s, with no 30 s rejoin wait. (b) It pauses with *Paused: open Shutter Bridge to join the camera's Wi-Fi, then the import carries on.* and posts *Import paused. Open Shutter Bridge to continue.* | (a) Seconds from the failure to the next file starting, with the step times (wait, Bluetooth, status 2, join, session); whether the wait before Bluetooth (decided, Shamil, 9 Nov: 30 s) was too long or too short. (b) The pause line shown (exact words) and whether the notification came (exact words); whether a Bluetooth switch-on from the background worked. | |
| 11 | **Proximity.** (a) Locked phone, camera brought into range. (b) During a USB or Wi-Fi import. (c) The 4-hour hold across a relaunch. (d) After a SIGKILL: stop the app from Xcode (Stop, or `kill -9`) with the camera out of range, and don't swipe it away (iOS doesn't relaunch a swiped-away app for Core Bluetooth). | (a) The reminder appears. (b) No reminder during a USB or Wi-Fi import. (c) The hold survives a relaunch. (d) iOS hands back the scan through `willRestoreState`. | (a) Seconds from coming into range to the reminder; RSSI; whether it needed the app-refresh task (the 30-minute re-arm is `unverified`) or a wake. (b) Reminders seen. (c) Whether a second arrival inside 4 hours reminded; what the quiet-gap comparison in the log shows. (d) Seconds from the relaunch to the report. | |

## Left from this run

To fill after the run: what failed, what was inconclusive, and which `unverified` constants a measurement now backs (each is marked in the code, listed in the backlog's status notes).

| Item | What was seen | Next step |
| --- | --- | --- |
| _to fill_ | | |
