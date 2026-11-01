# Fixtures

Bytes captured from the real camera during the spike. These are the ground truth the PTPKit codec is
tested against, and the record of what the α7C II actually said on each link.

The spike app saves them on the phone under `Documents/fixtures/a7c2/`, laid out exactly like this folder:
`usb/deviceinfo.bin` on the phone is `Fixtures/a7c2/usb/deviceinfo.bin` here. Saving a file again replaces the
earlier capture of the same name. Which button saves what, day by day, is in
[docs/spike-runbook.md](../docs/spike-runbook.md).

## What goes where

| File | What it is | Saved by (spike app) | Day |
| --- | --- | --- | --- |
| `a7c2/usb/deviceinfo.bin` | Data phase of `GetDeviceInfo` through `requestSendPTPCommand` | Wired › Day 4 · PTP pass-through › *GetDeviceInfo* | 4 |
| `a7c2/usb/FIRMWARE` | One line: camera model and firmware version from `GetDeviceInfo` | the same | 4 |
| `a7c2/usb/storageids.bin` | Data phase of `GetStorageIDs` | *GetStorageIDs + GetStorageInfo* | 4 |
| `a7c2/usb/storageinfo.bin` | Data phase of `GetStorageInfo` for the first store that answers OK | the same | 4 |
| `a7c2/usb/objecthandles.bin` | Data phase of `GetObjectHandles` | *GetObjectHandles* | 4 |
| `a7c2/usb/objectinfo-arw.bin`, `objectinfo-jpg.bin`, `objectinfo-hif.bin`, `objectinfo-mp4.bin` | Data phase of `GetObjectInfo` for the newest ARW, its JPG and/or HIF pair (or the newest JPG and HIF if it has no pair), and the newest MP4 if there is one | *GetObjectInfo: newest ARW + pair* | 4 |
| `a7c2/usb/event-objectadded.bin` | One PTP event container: the first new-object event (0x4002 or Sony 0xC201) of the session | any time a session is open; *Watch for ObjectAdded (60 s)* | 4 |
| `a7c2/usb/event-<xxxx>.bin` | One PTP event container: the first of each other event code, `xxxx` being the code in 4 lowercase hex digits | any time a session is open | 4–5 |
| `a7c2/usb/getpartialobject-<filename>.sha256` | Text: a `sha256sum` line for one ARW reassembled with `GetPartialObject` in 4 MiB chunks, then its size and the SHA-256 of the reassembly, of a `requestReadData` copy and of a `requestDownload` copy | *GetPartialObject: newest ARW* | 4 |
| `a7c2/ptpip/deviceinfo.bin` | Data phase of `GetDeviceInfo` over PTP/IP | Wi-Fi › Day 7 · Handshake › *Connect + OpenSession + GetDeviceInfo* (and *Reconnect*) | 7 |
| `a7c2/ptpip/FIRMWARE` | One line: camera model and firmware version | the same | 7 |
| `a7c2/ptpip/storageids.bin` | Data phase of `GetStorageIDs` | Wi-Fi › Day 8 · Enumerate and download › *List card* | 8 |
| `a7c2/ptpip/storageinfo.bin` | Data phase of `GetStorageInfo` for the first storage with a logical store | the same | 8 |
| `a7c2/ptpip/objecthandles.bin` | Data phase of `GetObjectHandles` for the first storage | the same | 8 |
| `a7c2/ptpip/objectinfo-arw.bin`, `objectinfo-jpg.bin`, `objectinfo-hif.bin`, `objectinfo-mp4.bin` | Data phase of `GetObjectInfo` for the first object of each kind in the listing | the same | 8 |
| `a7c2/ptpip/event-objectadded.bin` | One whole PTP/IP Event packet, header included: the first new-object event (0x4002 or 0xC201) of the app run | any time a session is open; *Shutter test (20 s)* | 8 |
| `a7c2/ptpip/event-<xxxx>.bin` | One whole PTP/IP Event packet: the first of each other event code | any time a session is open | 7–9 |
| `a7c2/ptpip/getobject.sha256` | Text: SHA-256, filename and size of the newest ARW fetched with `GetObject` | Wi-Fi › Day 9 · Resume, discovery, join › *Reference hash (GetObject newest ARW)* | 9 |
| `a7c2/ptpip/getpartialobject.sha256` | Text: SHA-256, filename, size, `GetPartialObject` variant and number of resumes of the reassembled ARW | *Start resumable read (newest ARW)* and *Resume read*, when the file is complete | 9 |
| `a7c2/ptpip/sdio-extdeviceinfo.bin` | Data phase of Sony's `SDIO_GetExtDeviceInfo` (experimental) | Day 7 · Handshake › *Sony SDIO connect (PC Remote modes)* | 7 |
| `a7c2/ptpip/ssdp-description.xml` | The UPnP device description fetched from an SSDP reply's `LOCATION` | Day 6 · Probe › *SSDP M-SEARCH to camera IP* or *SSDP M-SEARCH multicast* | 6, 9 |
| `a7c2/ptpip/<what>.pcap` | `tcpdump` captures on the Mac: SSDP and the handshake, per camera mode (for example `ssdp-<mode>.pcap`, `handshake-<mode>.pcap`) | Mac, by hand | 6, 9 |
| `a7c2/ble/advert-<on\|asleep\|off>.json` | The latest advertisement snapshot for that camera power state | Bluetooth › Day 6 · BLE advertisement › *Save snapshot* | 6 |
| `a7c2/ble/advert-<on\|asleep\|off>-<connected\|unlinked\|unpaired>.json` | The same snapshot, named by pairing context as well: *Creators' App connected*, *Creators' App quit, link down*, *Not paired* | the same | 6 |

Each BLE snapshot holds the power state and pairing context; when the scan started and ended (`scanEndedAt` is
null if the scan was still running) and `scanSeconds`, from scan start to *Stop*; the scan filter and options;
the proximity filter UUID; the phone and app build; full statistics for camera-like peripherals only (no
neighbours' device names), and a count of the others; the `retrieveConnectedPeripherals` query and its results;
and a note on how to read it.

## Naming

- Datasets: `<what>.bin`, or `<what>-<kind>.bin` where there is one per kind (`objectinfo-arw.bin`).
- Events: `event-objectadded.bin` for the first new-object event, `event-<xxxx>.bin` for the first of every other
  code. Over USB a file is one PTP event container; over PTP/IP it is one whole Event packet.
- Hashes: `<what>.sha256`, plain text.
- BLE: `advert-<state>.json` and `advert-<state>-<pairing>.json`.
- `FIRMWARE` in `usb/` and `ptpip/`: the model and firmware the fixtures in that folder came from.
- Mac captures: `<what>.pcap`.

## Getting them off the phone

- Log tab › Fixtures › *Share fixtures (zip)*, then AirDrop or save the `a7c2-fixtures-<timestamp>.zip` to the Mac.
  It holds an `a7c2` folder; copy it over this folder's `a7c2/` (for example with `ditto`).
- Or the Files app: On My iPhone › SB Spike › fixtures › a7c2. Or Finder on the Mac with the phone connected: the
  iPhone › Files › SB Spike.

Then run `make fixtures`. It copies every `Fixtures/a7c2/<link>/<name>.bin` to
`Packages/PTPKit/Tests/PTPKitTests/Fixtures/a7c2-<link>-<name>.bin`, where the PTPKit tests find them
automatically; `make test` then runs them. Only `.bin` files are copied: `FIRMWARE`, `.sha256`, `.json`, `.xml`
and `.pcap` files stay here as the record.

## Rules

- Never edit a fixture by hand. If a test fails on one, the codec is wrong.
- Nothing in here may contain the camera's Wi-Fi password or a QR payload. The spike app never writes either;
  scrub any pcap of the QR or join step.
- `deviceinfo.bin` and `ssdp-description.xml` may contain the camera's serial number.
