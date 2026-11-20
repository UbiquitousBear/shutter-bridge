import CameraTransport
import Foundation
import ImportEngine
import Testing
@testable import AppUI

// Auto-import's copy (backlog section 14): British English, "automatically" in Browse's notices, and no camera maker's
// marks in Settings.

@Suite("Auto-import: the wording")
struct AutoImportWordingTests {
    @Test func noticesSayAutomatically() {
        let started = StatusNotice.autoImport(.started(2), id: 3)
        #expect(started.text == "Importing 2 files automatically.")
        #expect(started.id == 3 && started.tone == .info && started.dismissesItself)
        #expect(started.systemImage == "square.and.arrow.down")
        let staging = StatusNotice.autoImport(.started(1), choice: .staging)
        #expect(staging.text == "Staging 1 file automatically.")
        #expect(staging.systemImage == "tray.and.arrow.down")
        #expect(StatusNotice.autoImport(.appended(3)).text == "Added 3 files to the import automatically.")
        #expect(StatusNotice.autoImport(.appended(3), choice: .staging).text == "Added 3 files to staging automatically.")
        #expect(StatusNotice.autoImport(.nothingNew(staging: false)).text == "No new photos to import.")
        #expect(StatusNotice.autoImport(.nothingNew(staging: true), choice: .staging).text == "No new photos to stage.")
        // Photos access off: an Import to Photos stages, and nothing new says so.
        #expect(StatusNotice.autoImport(.nothingNew(staging: true)).text == "No new photos to stage.")
        #expect(StatusNotice.autoImport(.nothingNew(staging: false)).dismissesItself)
    }

    @Test func refusalsKeepTheImportWording() {
        for outcome in [ImportRequestOutcome.busyWithAnotherCamera, .busyWithKeepers, .stillStarting,
                        .busyWithAnotherMode(.staging), .failed("The engine refused.")] {
            #expect(StatusNotice.autoImport(outcome, id: 7) == StatusNotice.importRequest(outcome, id: 7))
            #expect(StatusNotice.autoImport(outcome).tone == .problem)
        }
    }

    @Test func theFooterNamesNoCameraMakerAndTheModesByTheirCameraWording() {
        let copy = [AutoImportWording.header, AutoImportWording.footer, AutoImportWording.mscNote,
                    AutoImportWording.noCameras, AutoImportWording.toggleHint, AutoImportWording.saveFailed]
        for text in copy {
            #expect(!text.lowercased().contains("sony"), "\(text)")
            #expect(!text.contains("α"), "\(text)")
            #expect(!text.contains("color") && !text.contains("behavior"), "\(text)")
        }
        #expect(AutoImportWording.header == "Import When Connected")
        #expect(AutoImportWording.mscNote.hasPrefix(USBMode.massStorage.cameraWording + " can't tell cameras apart"))
        #expect(AutoImportWording.noCameras
            == "A camera is listed here once its card has been read in Image Transfer (MTP) or over Wi-Fi.")
        #expect(AutoImportWording.footer.contains("USB connection mode in the camera's menu"))
        #expect(AutoImportWording.footer.contains("a reminder never starts an import by itself"))
    }
}
