#!/usr/bin/env python3
"""Zero the camera's serial number in captured fixtures, keeping every other byte.

The repository is public, so the owner decided (1 Nov 2026) that a serial number never reaches it: each of its
characters becomes "0", and the length and every other byte stay as captured, so the PTPKit tests still parse
the real layout. Two kinds of file carry it:

- `deviceinfo.bin` (GetDeviceInfo's data phase, USB or PTP/IP; also the copies `make fixtures` puts in the PTPKit
  test bundle as `a7c2-<link>-deviceinfo.bin`): the SerialNumber string, the last field PTP defines.
- `ssdp-description.xml` (the UPnP device description): the text of each `<serialNumber>` element.

Packet captures are not redacted here: a pcap of the PTP/IP handshake also names the Mac, so pcaps stay out of the
repository altogether (`.gitignore` under `Fixtures/`, and the pre-commit hook refuses any staged `.pcap`).

Usage:
    scripts/redact-fixtures.py            zero the serial in every such file under Fixtures/ and the test bundle
    scripts/redact-fixtures.py FILE...    the same, for these files only
    scripts/redact-fixtures.py --check [FILE...]
                                          change nothing; exit 1 if a file still has a serial, or can't be read
                                          (the pre-commit hook runs this on staged fixtures)
A file's kind is taken from its name, so a staged copy in a temporary folder must keep the original basename.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_GLOBS = [
    "Fixtures/**/deviceinfo.bin",
    "Fixtures/**/ssdp-description.xml",
    "Packages/PTPKit/Tests/PTPKitTests/Fixtures/*deviceinfo.bin",
]
ZERO_UNIT = b"\x30\x00"  # "0" in UTF-16LE


class Unreadable(Exception):
    pass


def _u8(data, at):
    if at + 1 > len(data):
        raise Unreadable(f"ends at byte {len(data)}, needed a byte at {at}")
    return data[at], at + 1


def _skip(data, at, count, what):
    if at + count > len(data):
        raise Unreadable(f"{what} runs past the end ({at + count} > {len(data)})")
    return at + count


def _skip_u16_array(data, at, what):
    at_count = _skip(data, at, 4, what + " count")
    count = int.from_bytes(data[at:at + 4], "little")
    return _skip(data, at_count, 2 * count, what)


def _string_span(data, at, what):
    """A PTP string: a u8 count of UTF-16LE code units including the NUL (0 for an empty string), then the units.
    Returns (first unit offset, offset after the last unit, unit count)."""
    count, at = _u8(data, at)
    end = _skip(data, at, 2 * count, what)
    return at, end, count


def deviceinfo_serial_span(data):
    """Offsets of the SerialNumber code units (NUL excluded) in a DeviceInfo dataset."""
    at = _skip(data, 0, 2 + 4 + 2, "StandardVersion, VendorExtensionID and VendorExtensionVersion")
    _, at, _ = _string_span(data, at, "VendorExtensionDesc")
    at = _skip(data, at, 2, "FunctionalMode")
    for what in ("OperationsSupported", "EventsSupported", "DevicePropertiesSupported", "CaptureFormats",
                 "ImageFormats"):
        at = _skip_u16_array(data, at, what)
    for what in ("Manufacturer", "Model", "DeviceVersion"):
        _, at, _ = _string_span(data, at, what)
    start, end, count = _string_span(data, at, "SerialNumber")
    if count and data[end - 2:end] != b"\x00\x00":
        raise Unreadable("SerialNumber is not NUL-terminated")
    return start, (end - 2 if count else end)


def redact_deviceinfo(data):
    start, end = deviceinfo_serial_span(data)
    serial = data[start:end]
    if all(serial[i:i + 2] == ZERO_UNIT for i in range(0, len(serial), 2)):
        return data, 0
    redacted = bytearray(data)
    redacted[start:end] = ZERO_UNIT * ((end - start) // 2)
    return bytes(redacted), (end - start) // 2


SERIAL_ELEMENT = re.compile(rb"(<serialNumber>)(.*?)(</serialNumber>)", re.DOTALL | re.IGNORECASE)


def redact_ssdp(data):
    changed = 0

    def zero(match):
        nonlocal changed
        text = match.group(2)
        if text.strip(b"0") == b"":
            return match.group(0)
        changed += len(text)
        return match.group(1) + b"0" * len(text) + match.group(3)

    return SERIAL_ELEMENT.sub(zero, data), changed


def kind(path):
    name = path.name
    if name.endswith("deviceinfo.bin"):
        return redact_deviceinfo
    if name == "ssdp-description.xml":
        return redact_ssdp
    return None


def main(argv):
    check = "--check" in argv
    names = [a for a in argv if a != "--check"]
    if names:
        paths = [pathlib.Path(n) for n in names]
    else:
        paths = sorted({p for g in DEFAULT_GLOBS for p in ROOT.glob(g) if p.is_file()})
    problems = 0
    for path in paths:
        redact = kind(path)
        if redact is None:
            continue
        try:
            data = path.read_bytes()
            redacted, units = redact(data)
        except (OSError, Unreadable) as error:
            print(f"redact-fixtures: {path}: can't check the serial number: {error}", file=sys.stderr)
            problems += 1
            continue
        if not units:
            continue
        if check:
            print(f"redact-fixtures: {path} still contains a serial number ({units} characters); "
                  f"run scripts/redact-fixtures.py (or make fixtures) and stage the file again", file=sys.stderr)
            problems += 1
        else:
            path.write_bytes(redacted)
            print(f"redact-fixtures: {path}: serial number zeroed ({units} characters)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
