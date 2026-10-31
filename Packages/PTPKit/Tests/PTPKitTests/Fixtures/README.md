# PTPKit test fixtures

Bytes captured from the real α7C II during the spike go here so the codec is tested against the
camera's own output rather than the spec's prose. The test suite looks for:

| File | Captured on | Produced by |
| --- | --- | --- |
| `a7c2-deviceinfo.bin` | Spike day 4 (USB) or day 7 (PTP/IP) | the data phase of `GetDeviceInfo` |
| `a7c2-objectinfo-arw.bin` | day 4 / day 8 | the data phase of `GetObjectInfo` for an `.ARW` |
| `a7c2-objectinfo-jpg.bin` | day 4 / day 8 | the same for the paired `.JPG` / `.HIF` |
| `a7c2-event-objectadded.bin` | day 4 | one event container from `ptpEventHandler` |

Until a file exists its test returns early. The canonical copies live in `/Fixtures/a7c2/` at the repo
root; copy (don't move) the ones the tests need into this folder.
