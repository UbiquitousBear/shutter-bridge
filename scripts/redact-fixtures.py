#!/usr/bin/env python3
"""Zero the camera's serial number and hardware ID in captured fixtures, keeping every other byte.

The repository is public, so the owner decided (1 Nov 2026) that a serial number never reaches it, and (2 Nov 2026)
that the camera's hardware ID gets the same treatment: each character becomes "0", and the length and every other
byte stay as captured, so the PTPKit tests still parse the real layout. Two kinds of file carry them:

- `deviceinfo.bin` (GetDeviceInfo's data phase, USB or PTP/IP; also the copies `make fixtures` puts in the PTPKit
  test bundle as `a7c2-<link>-deviceinfo.bin`): the SerialNumber string, the last field PTP defines.
- `ssdp-description.xml` (the UPnP device description): the text of each serialNumber element, with or without a
  namespace prefix, attributes or spaces in the tag, closed or not (whitespace is kept). If an XML parser still
  finds a serialNumber that isn't all zeros afterwards (CDATA, an entity), the file is reported and not written.
  The same file carries the hardware ID: 12 hex digits that look like the camera's MAC address, the last group of
  the UDN (`uuid:00000000-0005-0010-8000-<12 hex digits>`), repeated in the USN values and possibly elsewhere. Every
  occurrence of those digits, in either letter case, anywhere in the file becomes `000000000000`. An XML parser must
  find no UDN with a non-zero ID afterwards either, or the file is reported and not written. The PTP/IP responder
  GUID (Init_Command_Ack) ends in the same 6 bytes, but the spike saves no handshake packet, and none of the other
  PTP/IP fixtures (datasets, whole Event packets) carries a GUID, so no binary fixture is touched for it. If one is
  ever saved, add its kind here first. `sdio-extdeviceinfo.bin` is Sony's private dataset and its layout is
  unverified, so it is left as captured; check it by eye before committing it.

Packet captures are not redacted here: a pcap of the PTP/IP handshake also names the Mac, so pcaps stay out of the
repository altogether (`.gitignore` under `Fixtures/`, and the pre-commit hook refuses any staged `.pcap`).

Usage:
    scripts/redact-fixtures.py            zero the serial and the hardware ID in every such file under Fixtures/
                                          and the test bundle
    scripts/redact-fixtures.py FILE...    the same, for these files only
    scripts/redact-fixtures.py --check [FILE...]
                                          change nothing; exit 1 if a file still has a serial or a hardware ID,
                                          or can't be read
                                          (the pre-commit hook runs this on staged fixtures)
A file's kind is taken from its name, so a staged copy in a temporary folder must keep the original basename.
"""

import pathlib
import re
import sys
from xml.etree import ElementTree

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_GLOBS = [
    "Fixtures/**/deviceinfo.bin",
    "Fixtures/**/ssdp-description.xml",
    "Packages/PTPKit/Tests/PTPKitTests/Fixtures/*deviceinfo.bin",
]
ZERO_UNIT = b"\x30\x00"  # "0" in UTF-16LE
# What a redactor can find, as the first item of each (kind, count) it returns.
SERIAL = "serial number"
HARDWARE_ID = "hardware ID"
HARDWARE_ZEROS = b"000000000000"


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
        return data, []
    redacted = bytearray(data)
    redacted[start:end] = ZERO_UNIT * ((end - start) // 2)
    return bytes(redacted), [(SERIAL, (end - start) // 2)]


# A <serialNumber> element as DeviceDescriptionParser in the spike sees one: any namespace prefix, attributes or
# spaces in the tag, any case. Its text ends at the closing tag, at the next tag if it is never closed, or at the end
# of a truncated file.
SERIAL_ELEMENT = re.compile(
    rb"<(?:[\w.-]+:)?serialNumber\b[^>]*>(.*?)(?:</(?:[\w.-]+:)?serialNumber\s*>|(?=<)|\Z)",
    re.DOTALL | re.IGNORECASE)
WHITESPACE = b" \t\r\n"


def _zeroed(text):
    """Every non-whitespace byte of `text` becomes "0" (length kept), and how many changed."""
    out = bytes(c if c in WHITESPACE else 0x30 for c in text)
    return out, sum(1 for a, b in zip(text, out) if a != b)


def _xml_serials(data):
    """The text of every serialNumber element, by an XML parser, or None if the file doesn't parse."""
    try:
        root = ElementTree.fromstring(data)
    except ElementTree.ParseError:
        return None
    return ["".join(e.itertext()) for e in root.iter()
            if isinstance(e.tag, str) and e.tag.rsplit("}", 1)[-1].rsplit(":", 1)[-1].lower() == "serialnumber"]


# A UDN element as DeviceDescriptionParser in the spike sees one (any namespace prefix, attributes or spaces in the
# tag, any case) whose value is `uuid:` and a UUID. Group 1 is the UUID's last group, 12 hex digits: the camera's
# hardware ID. Same pattern as FixtureStore.ssdpUDNPattern in the spike.
UDN_ELEMENT = re.compile(
    rb"<(?:[\w.-]+:)?UDN\b[^>]*>\s*uuid:[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-([0-9A-F]{12})",
    re.IGNORECASE)
UDN_VALUE = re.compile(r"uuid:[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-([0-9A-F]{12})", re.IGNORECASE)


def _xml_udn_ids(data):
    """The last group of every UDN element's UUID, by an XML parser, or None if the file doesn't parse."""
    try:
        root = ElementTree.fromstring(data)
    except ElementTree.ParseError:
        return None
    ids = []
    for e in root.iter():
        if isinstance(e.tag, str) and e.tag.rsplit("}", 1)[-1].rsplit(":", 1)[-1].lower() == "udn":
            match = UDN_VALUE.search("".join(e.itertext()).strip())
            if match:
                ids.append(match.group(1))
    return ids


def _zero_hardware_id(data):
    """`data` with every occurrence, in any case, of each UDN's non-zero hardware ID replaced by twelve "0"s, and
    how many occurrences were replaced. The IDs come from the UDN elements; the replacement is everywhere."""
    ids = {m.group(1).lower() for m in UDN_ELEMENT.finditer(data)} - {HARDWARE_ZEROS}
    replaced = 0
    for found in ids:
        # Hex digits only, so the literal needs no more than re.escape.
        data, count = re.subn(re.escape(found), HARDWARE_ZEROS, data, flags=re.IGNORECASE)
        replaced += count
    return data, replaced


def redact_ssdp(data):
    changed = 0

    def zero(match):
        nonlocal changed
        start, end = match.span(1)
        text, count = _zeroed(match.group(1))
        changed += count
        whole = match.group(0)
        offset = start - match.start()
        return whole[:offset] + text + whole[offset + (end - start):]

    redacted = SERIAL_ELEMENT.sub(zero, data)
    # Belt and braces: an XML parser must find nothing but zeros either (CDATA, entities, forms the pattern misses).
    for text in _xml_serials(redacted) or []:
        if any(ch not in "0 \t\r\n" for ch in text):
            raise Unreadable("an XML parser still finds a serialNumber that isn't all zeros after zeroing "
                             "(CDATA or an entity?); don't commit this file")
    redacted, hardware = _zero_hardware_id(redacted)
    # Same again for the hardware ID: an XML parser must read nothing but zeros in every UDN's last group.
    for found in _xml_udn_ids(redacted) or []:
        if found.strip("0"):
            raise Unreadable("an XML parser still finds a UDN with a hardware ID that isn't all zeros after zeroing "
                             "(CDATA or an entity?); don't commit this file")
    return redacted, [(kind_, count) for kind_, count in ((SERIAL, changed), (HARDWARE_ID, hardware)) if count]


def kind(path):
    name = path.name
    if name.endswith("deviceinfo.bin"):
        return redact_deviceinfo
    if name == "ssdp-description.xml":
        return redact_ssdp
    return None


def describe(what, count):
    return f"{count} characters" if what == SERIAL else f"{count} occurrence{'' if count == 1 else 's'}"


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
            redacted, findings = redact(data)
        except (OSError, Unreadable) as error:
            print(f"redact-fixtures: {path}: can't check the serial number or hardware ID: {error}", file=sys.stderr)
            problems += 1
            continue
        if not findings:
            continue
        if check:
            for what, count in findings:
                print(f"redact-fixtures: {path} still contains a {what} ({describe(what, count)}); "
                      f"run scripts/redact-fixtures.py (or make fixtures) and stage the file again", file=sys.stderr)
            problems += 1
        else:
            path.write_bytes(redacted)
            for what, count in findings:
                print(f"redact-fixtures: {path}: {what} zeroed ({describe(what, count)})")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
