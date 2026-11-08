import Testing
import Foundation
@testable import PTPKit

/// Bytes captured from the real α7C II, copied in by `make fixtures` as `a7c2-<link>-<name>.bin`, where link is
/// `usb` or `ptpip` and name is what the spike app saved (see Fixtures/README.md). Each test here is skipped
/// until a fixture of its kind exists, and then checks every one of them: it decodes and re-encodes to exactly the
/// camera's bytes. What each fixture says is asserted in `PTPFixtureContentTests`.
enum CapturedFixtures {
    static var directory: URL? { Bundle.module.url(forResource: "Fixtures", withExtension: nil) }

    static var all: [URL] {
        guard let dir = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasPrefix("a7c2-") && $0.hasSuffix(".bin") }.sorted().map { dir.appendingPathComponent($0) }
    }

    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "fixture \(name) is not in the test bundle; run `make fixtures`" }
    }

    /// The bytes of one fixture by its bundle name, e.g. `a7c2-usb-deviceinfo.bin`. Throws if `make fixtures` hasn't
    /// copied it, so a test of a specific capture fails loudly instead of passing on nothing.
    static func data(_ name: String) throws -> Data {
        guard let url = all.first(where: { $0.lastPathComponent == name }) else { throw Missing(name: name) }
        return try Data(contentsOf: url)
    }

    /// Fixtures whose name, after `a7c2-<link>-`, starts with `kind`.
    static func named(_ kind: String) -> [(url: URL, link: String, name: String)] {
        all.compactMap { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[2].hasPrefix(kind) else { return nil }
            return (url, parts[1], parts[2])
        }
    }
}

@Suite("Captured α7C II fixtures")
struct PTPFixtureTests {

    @Test("DeviceInfo from the camera parses and is Sony's", .enabled(if: !CapturedFixtures.named("deviceinfo").isEmpty))
    func deviceInfo() throws {
        for f in CapturedFixtures.named("deviceinfo") {
            let data = try Data(contentsOf: f.url)
            let info = try PTPDeviceInfo.decode(data)
            #expect(info.manufacturer.lowercased().contains("sony"), "\(f.url.lastPathComponent)")
            // The α7C II reports Sony's 0x11 over PTP/IP in PC Remote and the MTP ID 0xFFFFFFFF over USB in MTP mode
            // (libgphoto2 maps the latter to Sony by the manufacturer).
            #expect(info.isSony, "\(f.url.lastPathComponent): vendor extension 0x\(String(info.vendorExtensionID, radix: 16))")
            #expect(info.model.uppercased().contains("ILCE"), "\(f.url.lastPathComponent)")
            #expect(!info.operationsSupported.isEmpty)
            // Re-encoding reproduces the camera's bytes exactly: no trailing vendor data in either capture.
            #expect(info.encode() == data, "\(f.url.lastPathComponent) does not round-trip")
        }
    }

    @Test("ObjectInfo from the camera parses with a filename, size, date and the right media kind",
          .enabled(if: !CapturedFixtures.named("objectinfo").isEmpty))
    func objectInfo() throws {
        for f in CapturedFixtures.named("objectinfo") {
            let data = try Data(contentsOf: f.url)
            let info = try PTPObjectInfo.decode(data)
            #expect(!info.filename.isEmpty, "\(f.url.lastPathComponent)")
            #expect(info.objectCompressedSize > 0, "\(f.url.lastPathComponent)")
            #expect(info.captureDate != nil, "\(f.url.lastPathComponent): capture date \(info.captureDateRaw)")
            let expected: PTPMediaKind? = switch f.name {
            case "objectinfo-arw": .raw
            case "objectinfo-jpg": .jpeg
            case "objectinfo-hif": .heif
            case "objectinfo-mp4": .video
            default: nil
            }
            if let expected { #expect(info.mediaKind == expected, "\(f.url.lastPathComponent): format \(info.objectFormat)") }
            #expect(info.encode() == data, "\(f.url.lastPathComponent) does not round-trip")
        }
    }

    @Test("StorageInfo from the camera parses and round-trips; over PTP/IP the capacity is 0",
          .enabled(if: !CapturedFixtures.named("storageinfo").isEmpty))
    func storageInfo() throws {
        for f in CapturedFixtures.named("storageinfo") {
            let data = try Data(contentsOf: f.url)
            let info = try PTPStorageInfo.decode(data)
            #expect(info.encode() == data, "\(f.url.lastPathComponent) does not round-trip")
            switch f.link {
            case "usb":
                #expect(info.maxCapacity > 0, "\(f.url.lastPathComponent)")
                #expect(info.freeSpaceInBytes <= info.maxCapacity, "\(f.url.lastPathComponent)")
            case "ptpip":
                // The camera fills capacity and free space with 0 over PTP/IP (docs/spike-findings.md: "capacity shown
                // as 0"; docs/iteration-1-backlog.md section 1). A caller must not read 0 as "full" or "unknown card".
                #expect(info.maxCapacity == 0, "\(f.url.lastPathComponent)")
                #expect(info.freeSpaceInBytes == 0, "\(f.url.lastPathComponent)")
            default:
                Issue.record("unknown link \(f.link) in \(f.url.lastPathComponent)")
            }
        }
    }

    @Test("Storage IDs and object handles arrays parse and round-trip",
          .enabled(if: !(CapturedFixtures.named("storageids") + CapturedFixtures.named("objecthandles")).isEmpty))
    func arrays() throws {
        for f in CapturedFixtures.named("storageids") {
            let data = try Data(contentsOf: f.url)
            let ids = try PTPStorageID.decodeArray(data)
            #expect(!ids.isEmpty, "\(f.url.lastPathComponent)")
            #expect(PTPStorageID.encodeArray(ids) == data, "\(f.url.lastPathComponent) does not round-trip")
        }
        for f in CapturedFixtures.named("objecthandles") {
            let data = try Data(contentsOf: f.url)
            let handles = try PTPObjectHandle.decodeArray(data)
            #expect(!handles.isEmpty, "\(f.url.lastPathComponent)")
            #expect(PTPObjectHandle.encodeArray(handles) == data, "\(f.url.lastPathComponent) does not round-trip")
        }
    }

    @Test("Events: USB containers and PTP/IP packets decode and re-encode; ObjectAdded fixtures signal a new object",
          .enabled(if: !CapturedFixtures.named("event").isEmpty))
    func events() throws {
        for f in CapturedFixtures.named("event") {
            let data = try Data(contentsOf: f.url)
            let code: PTPEventCode
            switch f.link {
            case "usb":
                let (container, consumed) = try PTPContainer.decode(data)
                #expect(container.type == .event, "\(f.url.lastPathComponent)")
                #expect(consumed == data.count, "\(f.url.lastPathComponent) holds more than one container")
                #expect(container.encode() == data, "\(f.url.lastPathComponent) does not round-trip")
                code = container.eventCode
            case "ptpip":
                let decoded = try #require(try PTPIP.Packet.decode(data), "\(f.url.lastPathComponent) is not a whole packet")
                #expect(decoded.consumed == data.count, "\(f.url.lastPathComponent) holds more than one packet")
                #expect(decoded.packet.type == .event, "\(f.url.lastPathComponent)")
                let event = try PTPIP.decodeEvent(decoded.packet)
                #expect(PTPIP.event(event.code, transactionID: event.transactionID, parameters: event.parameters).encode() == data,
                        "\(f.url.lastPathComponent) does not round-trip")
                code = event.code
            default:
                Issue.record("unknown link \(f.link) in \(f.url.lastPathComponent)")
                continue
            }
            if f.name.hasPrefix("event-objectadded") {
                #expect(code.signalsNewObject, "\(f.url.lastPathComponent): got \(code)")
            }
        }
    }

    /// A fixture of a kind this suite doesn't check would pass `make test` unseen. Every name must be one the golden
    /// tests above or the structural check in `PTPFixtureContentTests` (sdio-extdeviceinfo) handle.
    @Test("Every captured fixture is of a kind a test checks", .enabled(if: !CapturedFixtures.all.isEmpty))
    func everyFixtureIsCovered() {
        let checked = ["deviceinfo", "objectinfo", "storageinfo", "storageids", "objecthandles", "event", "sdio-extdeviceinfo"]
        for url in CapturedFixtures.all {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2).map(String.init)
            #expect(parts.count == 3 && ["usb", "ptpip"].contains(parts[1]) && checked.contains { parts[2].hasPrefix($0) },
                    "\(url.lastPathComponent) is not covered by a fixture test")
        }
    }
}

@Suite("Decoders never trap on garbage")
struct PTPRobustnessTests {
    @Test("Random bytes into every decoder: throw or succeed, never crash")
    func garbage() {
        var rng = SeededGenerator(seed: 0x15740)
        for round in 0 ..< 2_000 {
            let n = Int.random(in: 0 ... 96, using: &rng)
            var bytes = Data((0 ..< n).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
            // Half the time, make the leading length field plausible so decoders get past the first check.
            if round % 2 == 0, n >= 4 {
                let len = UInt32(n)
                bytes.replaceSubrange(0 ..< 4, with: [UInt8(len & 0xFF), UInt8(len >> 8 & 0xFF), 0, 0])
            }
            _ = try? PTPDeviceInfo.decode(bytes)
            _ = try? PTPObjectInfo.decode(bytes)
            _ = try? PTPStorageInfo.decode(bytes)
            _ = try? PTPStorageID.decodeArray(bytes)
            _ = try? PTPObjectHandle.decodeArray(bytes)
            _ = try? PTPContainer.decodeAll(bytes)
            _ = try? MTPObjectPropList.decode(bytes).summaries()
            _ = try? PTPPassThrough.decodeReply(bytes, Data(bytes.reversed()), for: PTPCommand.getDeviceInfo(tx: 1))
            if let packet = (try? PTPIP.Packet.decode(bytes))??.packet {
                _ = try? PTPIP.decodeInitCommandAck(packet)
                _ = try? PTPIP.decodeInitCommandRequest(packet)
                _ = try? PTPIP.decodeCmdResponse(packet)
                _ = try? PTPIP.decodeCmdRequest(packet)
                _ = try? PTPIP.decodeEvent(packet)
                _ = try? PTPIP.decodeStartData(packet)
                _ = try? PTPIP.decodeDataChunk(packet)
            }
            var decoder = PTPIPStreamDecoder(maxControlPacketLength: 4096)
            var transaction = PTPIPTransaction(transactionID: 1)
            if let events = try? decoder.feed(bytes) {
                for e in events { _ = try? transaction.consume(e) }
            }
            _ = PTPDateTime.parse(String(decoding: bytes, as: UTF8.self))
        }
    }
}
