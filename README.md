# Shutter Bridge

Import photos from a Sony α7C II to an iPhone over USB-C or Wi-Fi, with differential sync, resume, a
proximity reminder over Bluetooth LE, and direct delivery into Photos. iPhone only, iOS 27, Swift 6, SwiftUI.
Working title; no Sony marks in the name or icon.

The technical bet: speak the open standards the camera already supports — PTP (ISO 15740) over USB via
`ImageCaptureCore`, PTP/IP over Wi-Fi via our own Swift codec on `Network.framework` — rather than Sony's
proprietary phone protocol.

## Where things are

| Path | What |
| --- | --- |
| [`docs/proposal.md`](docs/proposal.md) | Proposal and architecture: goals, transports, frameworks, engine design, data model, screens with mockups, background and proximity design, privacy, testing, 15-week roadmap, risks. Exported from the [live doc](https://claude.ai/artifact/S9gWVRBNxFB63Qe2B1GbzT), which has the editable diagrams. |
| [`docs/spike-plan.md`](docs/spike-plan.md) | The two-week spike, day by day (3–13 Nov 2026): what to measure, pass criteria, go/no-go. |
| `Packages/PTPKit/` | Pure-Swift PTP and PTP/IP codec with Swift Testing tests. The only code written during the spike that is meant to survive it. |
| `Spike/` | Throwaway iPhone app for the spike: ImageCaptureCore browser and session, PTP pass-through, PTP/IP client, SSDP probe, BLE advertisement scanner, `BGContinuedProcessingTask` test, measurement log with export. |
| `Fixtures/` | Bytes captured from the real camera; ground truth for the codec tests. Empty until day 2. |
| `ci_scripts/` | Xcode Cloud post-clone step (generates the spike project). |

## Getting started (spike day 1)

Prerequisites: Apple-silicon Mac with Xcode 27, `brew install xcodegen gphoto2`, a base-model USB-C iPhone on
iOS 27 in Developer Mode, the α7C II on firmware 2.00+, a data-rated USB-C cable.

```sh
make spike            # generates Spike/Spike.xcodeproj from Spike/project.yml
make open             # opens it; set your team under Signing & Capabilities once
make test             # runs the PTPKit unit tests (macOS or Linux toolchain)
```

Then follow `docs/spike-plan.md`. The first thing to do on day 1 needs no code at all: set the camera's USB
mode to *Still Img Transfer (MTP)*, plug it into the iPhone, and see whether the Photos app offers to import.

The multicast entitlement (for SSDP discovery) must be requested from Apple on day 1; the key is commented
out in `Spike/Spike.entitlements` until it is granted, so signing works meanwhile.

## Status

- [x] Proposal, architecture, mockups, roadmap
- [x] Spike plan
- [x] PTPKit codec skeleton with tests
- [x] Spike app scaffold (compile and adjust against the iOS 27 SDK on day 1)
- [ ] Spike findings (day 10, 13 Nov 2026)
- [ ] Go / no-go on wireless scope for 1.0
- [ ] Production workspace (six packages) — after the go/no-go

## Decisions so far

Paid one-off app, English only at launch, stills only in 1.0 (video in 1.1), RAW+JPEG/HEIF pairs saved as
one Photos asset, Browse-and-pick on connect (auto-import is opt-in), both Wi-Fi setups (camera AP and home
LAN) first-class, BLE proximity reminder (dismissible alert with quiet hours) in 1.0, Bluetooth camera wake and
credential hand-off first after 1.0, plain SwiftUI with `@Observable` over an actor-based engine, Xcode Cloud
for CI, one engineer through Iteration 2 and a second from week 10.
