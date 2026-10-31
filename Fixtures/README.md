# Fixtures

Bytes captured from the real camera during the spike. These are the ground truth the PTPKit codec is
tested against, and the record of what the α7C II actually said on each link.

| Folder | What goes in it | Captured on |
| --- | --- | --- |
| `a7c2/usb/` | `GetDeviceInfo`, `GetObjectInfo` (one ARW, one JPG/HIF) and event containers from `ICCameraDevice.requestSendPTPCommand` / `ptpEventHandler`; the SHA-256 of one file reassembled with `GetPartialObject` | days 2–5 |
| `a7c2/ptpip/` | The same datasets over PTP/IP, plus a `tcpdump` pcap of the handshake and of SSDP on the camera AP and on the LAN | days 6–9 |
| `a7c2/ble/` | nRF Connect / LightBlue exports of the camera's advertisement with the camera on, asleep and powered off | day 6 |

Naming: `<what>-<state>.bin` for datasets (`deviceinfo.bin`, `objectinfo-arw.bin`, `event-objectadded.bin`),
`<what>.pcap` for captures, `advert-<on|asleep|off>.json` for BLE. Note the camera firmware version in a
`FIRMWARE` file in each folder. Copy — don't move — the files the unit tests need into
`Packages/PTPKit/Tests/PTPKitTests/Fixtures/`.

Nothing in here should contain the camera's Wi-Fi password: scrub pcaps of the QR/join step.
