# Remote shoot and live-view monitor: design notes

**Status: later scope** (Shamil, 9 Nov; [decision-pack.md](decision-pack.md), Part 2, *Choices decided by Shamil on 9 Nov*).
Nothing here is built. These notes collect what the reference apps show and the one requirement Shamil added, so the
remote-shoot spike and design start from them.

Over USB, remote control needs the camera's *Remote Shoot (PC Remote)* mode, which shares no files, so remote shoot is a
second mode of the app beside import. Over Wi-Fi the PTP/IP connection (`PTPIPConnection`, Iteration 3, W3) is built
separately from the whole-card contents session (W6), so a remote-control session can run on the same connection later.

## Reference apps

Shamil shared screenshots on 9 Nov of AlphaLuma's camera monitor, a third-party Sony companion app (portrait and
landscape, over Wi-Fi to the α7C II), and of Creators' App's remote screen. The screenshots aren't kept in the repository:
they show other companies' interfaces and Sony's marks. What follows is a description, not a copy, and the design takes
patterns only (decision of 9 Nov: no copying another app's branding or assets, no Sony marks).

What AlphaLuma's monitor does:

- **Layout.** Portrait: a status pill at the top (camera model, link, camera battery, phone battery, with a green dot for
  connected) and a close button; the live view in its 3:2 frame; a horizontally scrolling tool strip; a bar of exposure
  values (ISO, shutter, aperture, white balance, exposure compensation, then focus after a divider); a large shutter
  button at the bottom. Landscape: the exposure values in a column on one side, the shutter and a vertical tool strip on
  the other, the live view between.
- **Tools that change only the phone's view:** grid (off, rule of thirds, centre, diagonal), mirror, rotate and desqueeze
  (one panel, with a footnote that nothing is written to the camera), scopes (histogram or waveform, drawn over the live
  view), focus peaking, false colour, aspect masks.
- **Settings written to the camera**, each opened from the exposure bar into a panel: ISO (Auto switch, a log-scale
  slider with the camera's range, quick values, direct entry), shutter speed (the same, plus a warning when the camera
  locks the setting), aperture (range "reported by camera", quick stops), white balance (presets and A–B / G–M shift
  sliders with a reset), exposure compensation (±5 EV in thirds, quick −1, ±0, +1), focus (mode, area, tracking, what a
  tap on the view does).
- **Patterns worth keeping:** one floating panel at a time above the strip, with a title, the current value large and a
  Close; the strip's icons show their state; ranges come from what the camera reports, not a table; a locked setting
  explains why instead of silently not responding; a status pill that says which camera and which link at a glance.

What to do differently in Shutter Bridge:

- **System controls and Liquid Glass**, not custom orange segmented controls: `Picker` with the segmented style, system
  sliders and steppers, glass panels and toolbars (Shamil's 9 Nov direction), so Dynamic Type, VoiceOver and dark mode
  come with them. Labels must not wrap mid-word ("Desqueeze" wraps in AlphaLuma's mirror panel).
- **Mark what writes to the camera.** AlphaLuma's own launch post says its interface doesn't distinguish phone-only tools
  from settings written to the camera, and calls it the most confusing part. Every control that changes the camera should
  say so, and phone-only tools should say they don't.
- **Unknown is not zero.** AlphaLuma showed "Camera 0%" for a camera that wasn't reporting its battery (Creators' App
  showed the camera on external power). Show the value only when the camera reports one, as the import screens already do
  for battery and free space.
- **One rule for unavailable controls.** AlphaLuma hides some controls that don't apply and greys others. Prefer: hide
  what can't exist in this mode; show and explain what the camera is locking right now (as its shutter panel does).

## The level guide (Shamil's requirement, 9 Nov)

Neither AlphaLuma nor Creators' App shows a level. The monitor should have a **level guide for both axes**: horizontal
(roll, is the horizon straight) and vertical (pitch, is the camera tilted forward or back), as the camera's own
electronic level does on its screen. Drawn in the restrained style of the other guides, with a clear "level" state.

Where the reading comes from is the first thing the remote-shoot spike settles, in this order:

1. **The camera's own level, over PTP.** Whether the α7C II reports its level in the remote-control session is
   `unverified`. Check the property list the camera returns in that session (the contents session's
   SDIO_GetExtDeviceInfo reply, `Fixtures/a7c2/ptpip/sdio-extdeviceinfo.bin`, lists 421 codes, but remote control may list
   others) and Sony's published remote-control property set. If it's there, it's exact and works in any scene.
2. **Roll from the picture.** If the camera doesn't report it, Vision's `VNDetectHorizonRequest` gives the horizon's angle
   in a live-view frame (Apple frameworks only). It needs a visible horizon or strong horizontal lines, so it can't be
   the only source, and it gives no pitch.
3. **Pitch from the picture.** Converging verticals in the frame (keystone) hint at pitch; this is harder, and
   `unverified` as a reliable guide.
4. **The phone's own sensors** only help if the phone is fixed to the camera (a cold-shoe mount) and calibrated, which
   isn't the usual set-up.

Still to decide with Shamil when remote shoot is planned: whether the guide is on by default, its tolerance for "level",
and whether it can be calibrated.
