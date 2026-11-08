# PTPKit test fixtures

Bytes captured from the real α7C II during the spike, so the codec is tested against the camera's own output
rather than the spec's prose. The canonical copies live in `/Fixtures/a7c2/` at the repo root; `make fixtures`
copies them here, and nothing in this folder is edited by hand.

`make fixtures` copies every `Fixtures/a7c2/<link>/<name>.bin` to `a7c2-<link>-<name>.bin` here, where `<link>`
is `usb` or `ptpip` and `<name>` is the name the spike app saved (see [Fixtures/README.md](../../../../../Fixtures/README.md)).
For example `Fixtures/a7c2/usb/objectinfo-arw.bin` becomes `a7c2-usb-objectinfo-arw.bin`.

This folder is bundled with the tests as a resource. Each test in `PTPFixtureTests.swift` ("Captured α7C II
fixtures") picks up every file whose name, after `a7c2-<link>-`, starts with its kind, is skipped until at least
one exists, and then checks all of them: each decodes and **re-encodes to exactly the camera's bytes** (21 files
on 8 Nov: 20 round-trip, and `sdio-extdeviceinfo` has a structural check). `PTPFixtureContentTests.swift` pins what
each file holds, field by field (model, firmware string per mode, operation and event lists, sizes, formats,
dimensions, dates, thumbnails, parents, event codes and parameters).

| Kind (files) | Test | Checks |
| --- | --- | --- |
| `deviceinfo` (`a7c2-usb-deviceinfo.bin`, `a7c2-ptpip-deviceinfo.bin`) | `deviceInfo()`, "DeviceInfo from the camera parses and is Sony's" | decodes; the manufacturer contains "Sony", the device counts as Sony (`isSony`: vendor extension 0x11, or the MTP ID 0xFFFFFFFF or 0x6 from a Sony manufacturer, as libgphoto2 treats it) and the model contains "ILCE"; the operations list is not empty; re-encoding gives the same bytes |
| `objectinfo` (`a7c2-<link>-objectinfo-arw.bin`, `-jpg`, `-hif`, `-mp4`) | `objectInfo()`, "ObjectInfo from the camera parses with a filename, size, date and the right media kind" | decodes with a filename, a size above zero and a capture date that parses; the media kind matches the name (`arw` raw, `jpg` JPEG, `hif` HEIF, `mp4` video); re-encoding gives the same bytes |
| `storageinfo` (`a7c2-<link>-storageinfo.bin`) | `storageInfo()`, "StorageInfo from the camera parses and round-trips; over PTP/IP the capacity is 0" | decodes and re-encodes to the same bytes; over USB, capacity above zero and free space no larger than capacity; over PTP/IP, capacity and free space both 0 (the camera's way of saying nothing) |
| `storageids`, `objecthandles` (`a7c2-<link>-storageids.bin`, `a7c2-<link>-objecthandles.bin`) | `arrays()`, "Storage IDs and object handles arrays parse and round-trip" | each decodes to a non-empty array and re-encodes to the same bytes |
| `event` (`a7c2-<link>-event-objectadded.bin`, `a7c2-<link>-event-<xxxx>.bin`) | `events()`, "Events: USB containers and PTP/IP packets decode and re-encode; ObjectAdded fixtures signal a new object" | over USB, one container of type event; over PTP/IP, one whole packet that decodes as an Event; either re-encodes to the same bytes; an `event-objectadded` file must carry 0x4002 or Sony's 0xC201 |
| `sdio-extdeviceinfo` (`a7c2-ptpip-sdio-extdeviceinfo.bin`) | `extDeviceInfoLayout()` in `PTPFixtureContentTests` | no parser in PTPKit: a u16 version (0x12C), then two lists of a u32 count and u16 codes (421 and 59), consuming all 970 B; seen in one capture |
| any `a7c2-<link>-*.bin` | `everyFixtureIsCovered()` | the name's kind is one of the above, so a new kind of fixture can't sit unchecked |

Only `.bin` files are copied. The `FIRMWARE`, `.sha256`, `.json` and `.xml` files stay in
`/Fixtures/a7c2/`; the Mac's `.pcap` captures never enter the repo.

If a test fails on a fixture, the codec disagrees with the camera: fix the codec, not the fixture.
