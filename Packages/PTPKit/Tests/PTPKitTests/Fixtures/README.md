# PTPKit test fixtures

Bytes captured from the real α7C II during the spike, so the codec is tested against the camera's own output
rather than the spec's prose. The canonical copies live in `/Fixtures/a7c2/` at the repo root; `make fixtures`
copies them here, and nothing in this folder is edited by hand.

`make fixtures` copies every `Fixtures/a7c2/<link>/<name>.bin` to `a7c2-<link>-<name>.bin` here, where `<link>`
is `usb` or `ptpip` and `<name>` is the name the spike app saved (see [Fixtures/README.md](../../../../../Fixtures/README.md)).
For example `Fixtures/a7c2/usb/objectinfo-arw.bin` becomes `a7c2-usb-objectinfo-arw.bin`.

This folder is bundled with the tests as a resource. Each test in `PTPFixtureTests.swift` ("Captured α7C II
fixtures") picks up every file whose name, after `a7c2-<link>-`, starts with its kind, is skipped until at least
one exists, and then checks all of them:

| Kind (files) | Test | Checks |
| --- | --- | --- |
| `deviceinfo` (`a7c2-usb-deviceinfo.bin`, `a7c2-ptpip-deviceinfo.bin`) | `deviceInfo()`, "DeviceInfo from the camera parses and is Sony's" | decodes; the manufacturer contains "Sony", the vendor extension is Sony's and the model contains "ILCE"; the operations list is not empty; re-encoding reproduces the camera's bytes (trailing vendor data is not modelled) |
| `objectinfo` (`a7c2-<link>-objectinfo-arw.bin`, `-jpg`, `-hif`, `-mp4`) | `objectInfo()`, "ObjectInfo from the camera parses with a filename, size, date and the right media kind" | decodes with a filename, a size above zero and a capture date that parses; the media kind matches the name (`arw` raw, `jpg` JPEG, `hif` HEIF, `mp4` video); re-encoding reproduces the bytes |
| `storageinfo` (`a7c2-<link>-storageinfo.bin`) | `storageInfo()`, "StorageInfo from the camera parses" | decodes; capacity above zero and free space no larger than capacity |
| `storageids`, `objecthandles` (`a7c2-<link>-storageids.bin`, `a7c2-<link>-objecthandles.bin`) | `arrays()`, "Storage IDs and object handles arrays parse" | each decodes to a non-empty array |
| `event` (`a7c2-<link>-event-objectadded.bin`, `a7c2-<link>-event-<xxxx>.bin`) | `events()`, "Events: USB containers and PTP/IP packets decode; ObjectAdded fixtures signal a new object" | over USB, one container of type event; over PTP/IP, one whole packet that decodes as an Event; an `event-objectadded` file must carry 0x4002 or Sony's 0xC201 |
| `sdio-extdeviceinfo` (`a7c2-ptpip-sdio-extdeviceinfo.bin`) | none yet | copied by `make fixtures`, but PTPKit has no parser for Sony's ExtDeviceInfo |

Only `.bin` files are copied. The `FIRMWARE`, `.sha256`, `.json`, `.xml` and `.pcap` files stay in
`/Fixtures/a7c2/`.

If a test fails on a fixture, the codec disagrees with the camera: fix the codec, not the fixture.
