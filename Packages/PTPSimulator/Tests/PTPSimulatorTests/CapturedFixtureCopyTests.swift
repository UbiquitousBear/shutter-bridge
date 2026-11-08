import Foundation
import PTPKit
import Testing
@testable import PTPSimulator

@Suite("The simulator's fixture copies")
struct CapturedFixtureCopyTests {
    /// Each bundled copy and the repository fixture it was copied from (Sources/PTPSimulator/Fixtures/README.md).
    static let copies: [(copy: String, source: String)] = [
        ("a7c2-usb-deviceinfo", "usb/deviceinfo.bin"),
        ("a7c2-ptpip-deviceinfo", "ptpip/deviceinfo.bin"),
        ("a7c2-usb-storageinfo", "usb/storageinfo.bin"),
        ("a7c2-ptpip-storageinfo", "ptpip/storageinfo.bin"),
        ("a7c2-usb-objectinfo-arw", "usb/objectinfo-arw.bin"),
        ("a7c2-usb-objectinfo-jpg", "usb/objectinfo-jpg.bin"),
    ]

    /// A file under the repository's `Fixtures/a7c2/`, found from this source file's path; nil where the checkout
    /// isn't reachable (a test bundle run away from its sources).
    static func repositoryFixture(_ path: String, file: String = #filePath) -> Data? {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent() // PTPSimulatorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PTPSimulator
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // the repository
        return try? Data(contentsOf: root.appendingPathComponent("Fixtures/a7c2/\(path)"))
    }

    @Test func everyCopyLoadsAndDecodes() throws {
        for flavour in SimulatorFlavour.allCases {
            let info = try CapturedA7C2.deviceInfo(flavour)
            #expect(info.manufacturer == "Sony Corporation" && info.model == "ILCE-7CM2", "\(flavour)")
            #expect(info.serialNumber.count == 32 && info.serialNumber.allSatisfy { $0 == "0" }, "\(flavour)")
            #expect(try CapturedA7C2.storageInfo(flavour).storageType == 4)
        }
        #expect(try CapturedA7C2.objectInfoTemplate(raw: true).filename == "DSC02018.ARW")
        #expect(try CapturedA7C2.objectInfoTemplate(raw: false).filename == "DSC01997.JPG")
        #expect(throws: SimulatorFixtureError.self) { try CapturedA7C2.bytes("no-such-fixture") }
    }

    @Test func copiesMatchTheirSources() throws {
        for (copy, source) in Self.copies {
            let bundled = try CapturedA7C2.bytes(copy)
            guard let original = Self.repositoryFixture(source) else { continue }
            #expect(bundled == original, "\(copy) differs from Fixtures/a7c2/\(source): copy it again, never edit it")
        }
    }
}
