# The simulator's copies of the α7C II fixtures

Byte-for-byte copies of captured fixtures, bundled with the `PTPSimulator` target so the simulated camera answers
with the camera's own datasets (backlog section 7). PTPKit's copies are a resource of its *test* target, which
another package can't reach, hence these. Copied on 8 Nov 2026; never edit them. The serial numbers in both
DeviceInfo files were already zeroed by `scripts/redact-fixtures.py` (the pre-commit hook checks every
`*deviceinfo.bin`). `CapturedFixtureCopyTests` compares each copy with its source when the repository's
`Fixtures/` folder is reachable, so a later export that replaces a source shows up.

| Copy | Source | What the simulator uses it for |
| --- | --- | --- |
| `a7c2-usb-deviceinfo.bin` | `Fixtures/a7c2/usb/deviceinfo.bin` | GetDeviceInfo in the default flavour, MTP over USB (24 operations, 3 events, firmware string "2.0") |
| `a7c2-ptpip-deviceinfo.bin` | `Fixtures/a7c2/ptpip/deviceinfo.bin` | GetDeviceInfo in the PTP/IP flavour (81 operations, 48 events, firmware string "2.01") |
| `a7c2-usb-storageinfo.bin` | `Fixtures/a7c2/usb/storageinfo.bin` | GetStorageInfo in the MTP flavour (free space recomputed from the scripted card) |
| `a7c2-ptpip-storageinfo.bin` | `Fixtures/a7c2/ptpip/storageinfo.bin` | GetStorageInfo in the PTP/IP flavour, as sent (capacity and free space 0) |
| `a7c2-usb-objectinfo-arw.bin` | `Fixtures/a7c2/usb/objectinfo-arw.bin` | the thumbnail and pixel fields of every ARW's ObjectInfo |
| `a7c2-usb-objectinfo-jpg.bin` | `Fixtures/a7c2/usb/objectinfo-jpg.bin` | the same for every JPG (and, as a placeholder, every HIF: no HIF is captured) |
