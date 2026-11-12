# What to Test: Iteration 2 builds

Notes for the internal TestFlight testers, from the 15 Jan 2027 build (backlog section 9, D12). Paste the section
below into the build's *What to Test* field in App Store Connect: `testflight.yml` uploads the build but has no step
for release notes, so they are entered by hand. Keep them to what a tester can see and try: nothing about the people,
the cameras or the networks used on the bench, and no camera maker's marks (the notes show in the TestFlight app, as
the app's own copy does).

Everything still needs a camera that offers *Image Transfer (MSC)* or *Image Transfer (MTP)* over USB-C, or a camera
set up over Wi-Fi. Only the bench's camera model has been tried.

---

**New in this build**

- **Only the new photos.** Browse marks what is already imported or staged, *Select All New* picks the rest, and a
  second import of the same card copies nothing twice. Photos without a capture date are left out, and the import says
  how many.
- **Stops and starts.** Pull the cable, switch the camera off or walk out of Wi-Fi range mid-import: the import pauses
  and carries on when the camera is back, without duplicates or missing photos. An import cut short by closing the app
  shows as *Stopped early* in History, ready to resume.
- **History tab.** Every import, staging and *Import Keepers* job, newest first, with its counts, size, time and where
  the files went. *Resume* and *Re-run Failed Files* queue what is left; *Forget Imports* (in the menu) makes a
  camera's photos new again without touching Photos.
- **Staging tab and the loupe.** Stage photos to iCloud Drive (or this iPhone), then cull them with no camera
  connected: swipe up to keep, down to reject, left and right to move, pinch to zoom to 100 %, and add stars. A RAW and
  its JPEG are one photo. *Import Keepers* puts the keepers in Photos and then offers to remove the staged copies.
- **Rejects stay rejected.** A rejected photo is badged *Rejected* in Browse and left out of *Select All New*; tap the
  badge to lift it.
- **Shortcuts and Siri.** *Import New Photos* and *How Many New Photos* in the Shortcuts app.
- **Export Diagnostics…** in Settings makes a text file of the app's own log, with serial numbers, network names and
  addresses removed, and opens the share sheet. Nothing is sent unless you share it.
- **Card free space** on the Cameras screen, under a camera connected in *Image Transfer (MTP)*, once its card has been
  opened in Browse.

**Please try**

1. Import a card, shoot a few more photos, and import again: only the new ones should go.
2. Pull the cable halfway through a large import, then plug it back in, in the same USB mode. Check Photos for
   duplicates or gaps.
3. Stage a day's photos, cull them in the Staging tab with VoiceOver on and off, then *Import Keepers*.
4. Run *How Many New Photos* from Shortcuts with the camera connected, and again with it unplugged.
5. Use the app at the largest text size (Settings › Accessibility › Display & Text Size › Larger Text).

**Known limits**

- Over USB the app has to stay in front: an import pauses a few seconds after you leave it and carries on when you come
  back. Over Wi-Fi it keeps going in the background for a while.
- Videos are shown but not imported yet.
- Battery level isn't shown yet, and free space is shown only in *Image Transfer (MTP)*.

**When something goes wrong**

Send feedback from TestFlight (take a screenshot, then *Share Beta Feedback*), and attach the file from
*Settings › Export Diagnostics…* if you can. Say which USB mode or Wi-Fi the camera was in.
