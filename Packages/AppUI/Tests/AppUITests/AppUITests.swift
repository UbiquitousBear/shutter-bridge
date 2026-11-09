import CameraTransport
import Testing
@testable import AppUI

@Suite("Cameras empty state")
struct CamerasEmptyStateTests {
    let copy = CamerasEmptyState.standard

    @Test func usesTheCamerasWordingAndRecommendsMSC() {
        #expect(copy.modeAdvice.contains("Select USB Connect Mode"))
        #expect(copy.modeAdvice.contains("choose Image Transfer (MSC)"))
        #expect(copy.modeAdvice.contains("Image Transfer (MTP)"))
        #expect(copy.remoteShootNote.contains("Remote Shoot (PC Remote)"))
        #expect(copy.connect.contains("USB-C"))
    }

    @Test func noSonyMarksAndNoUnfinishedLines() {
        // "Works with" wording only: the copy never names the maker, and every line is a finished sentence.
        for line in copy.lines + [CamerasEmptyState.lookingNotice] {
            #expect(!line.lowercased().contains("sony"), "\(line)")
            #expect(!line.isEmpty)
        }
        for line in copy.lines.dropFirst() + [CamerasEmptyState.lookingNotice] {
            #expect(line.hasSuffix("."), "\(line)")
        }
    }
}

@Suite("Browse and Copy as JPEG wording")
struct WordingTests {
    /// Every sentence the slice can show, with the failure messages for every kind.
    var sentences: [String] {
        var lines = [
            CamerasWording.notAllowedDetail,
            CamerasWording.disconnected(CameraDescriptor(id: .init(rawValue: "a"), name: "Untitled",
                                                         mode: .usb(.massStorage))),
            CamerasWording.disconnected(CameraDescriptor(id: .init(rawValue: "b"), name: "ILCE-7CM2",
                                                         mode: .usb(.mtp))),
            BrowseWording.readingDetail(.usb(.massStorage)), BrowseWording.readingDetail(.usb(.mtp)),
            BrowseWording.noFilesDetail, BrowseWording.emptyCardDetail, BrowseWording.goneDetail,
            JPEGWording.copied(pressedName: "DSC00001.ARW", embeddedPreview: false), JPEGWording.copiedPreview,
            JPEGWording.sharingPreview,
        ]
        lines += CameraLinkFailure.Kind.allCases.map(BrowseWording.listingFailed)
        lines += CameraLinkFailure.Kind.allCases.compactMap { JPEGWording.failed(.link(CameraLinkFailure($0))) }
        lines += [JPEGActionFailure.conversion(detail: ""), .storage(detail: ""), .clipboard(detail: ""),
                  .shareUnavailable].compactMap(JPEGWording.failed)
        return lines
    }

    var labels: [String] {
        [CamerasWording.title, CamerasWording.usbBadge, CamerasWording.notAllowedTitle, CamerasWording.openSettings,
         BrowseWording.readingTitle, BrowseWording.noFilesTitle, BrowseWording.emptyCardTitle,
         BrowseWording.goneTitle, BrowseWording.listingFailedTitle, BrowseWording.tryAgain,
         BrowseWording.videoLabel, BrowseWording.otherLabel,
         BrowseWording.close, CamerasWording.genericName,
         JPEGWording.copyAction, JPEGWording.shareAction, JPEGWording.cancel]
            + USBMode.allCases.map { CamerasWording.modeLine(.usb($0)) }
    }

    @Test func noSonyMarksAndFinishedSentences() {
        for line in sentences {
            #expect(!line.lowercased().contains("sony"), "\(line)")
            #expect(line.hasSuffix("."), "\(line)")
        }
        for label in labels {
            #expect(!label.lowercased().contains("sony"), "\(label)")
            #expect(!label.isEmpty)
        }
    }

    @Test func theDecidedWordsAreThere() {
        #expect(JPEGWording.copyAction == "Copy as JPEG")
        #expect(JPEGWording.shareAction == "Share as JPEG…")
        #expect(BrowseWording.videoLabel == "Video: from 1.1")
        #expect(JPEGWording.copiedPreview == "Copied the camera's preview: this RAW couldn't be decoded on this iPhone.")
        #expect(JPEGWording.copied(pressedName: "DSC00001.ARW", embeddedPreview: true) == JPEGWording.copiedPreview)
        #expect(JPEGWording.copied(pressedName: "DSC00001.ARW", embeddedPreview: false) == "Copied DSC00001 as a JPEG.")
        #expect(JPEGWording.failed(.cancelled) == nil)
    }

    @Test func readingTheCardStatesTheMeasuredTimes() {
        let msc = BrowseWording.readingDetail(.usb(.massStorage))
        #expect(msc.contains("Image Transfer (MSC)") && msc.contains("7–12 seconds") && msc.contains("391–549"))
        let mtp = BrowseWording.readingDetail(.usb(.mtp))
        #expect(mtp.contains("Image Transfer (MTP)") && mtp.contains("65–123 seconds") && mtp.contains("391–825"))
        #expect(mtp.contains("all appear at the end"))
        #expect(BrowseWording.noFilesDetail.contains("Remote Shoot (PC Remote)"))
        #expect(BrowseWording.noFilesDetail.contains("Image Transfer (MSC)"))
        #expect(!BrowseWording.noFilesDetail.contains("empty"))   // an empty MTP card looks the same
        #expect(BrowseWording.elapsed(seconds: 9) == "9 s so far")
        #expect(BrowseWording.elapsed(seconds: 125) == "2 min 5 s so far")
        #expect(BrowseWording.elapsed(seconds: -3) == "0 s so far")
    }

    @Test func modeLines() {
        #expect(CamerasWording.modeLine(.usb(.massStorage)) == "Image Transfer (MSC)")
        #expect(CamerasWording.modeLine(.usb(.mtp)) == "Image Transfer (MTP) or Remote Shoot (PC Remote)")
        #expect(CamerasWording.modeLine(.usb(.remoteShoot)) == "Remote Shoot (PC Remote)")
    }

    @Test func benchLineHoldsNamesSizesAndTimesOnly() {
        var record = JPEGBenchRecord(path: .previewFallback, purpose: .copy, pressedName: "DSC00001.ARW",
                                     fetchedName: "DSC00001.ARW", fetchedBytes: 42_000_000, fetchSeconds: 1.049)
        record.renderSeconds = 0.5
        record.outputPixelSize = PixelSize(width: 1616, height: 1080)
        record.largestPreviewPixelSize = PixelSize(width: 1616, height: 1080)
        record.outputBytes = 812_345
        record.notes = ["CIRAWFilter(imageURL:) returned nil"]
        #expect(record.logLine == "copy-as-jpeg path=preview-fallback purpose=copy pressed=DSC00001.ARW "
            + "fetched=DSC00001.ARW fetched-bytes=42000000 fetch-s=1.05 render-s=0.50 output-px=1616x1080 "
            + "output-bytes=812345 largest-preview-px=1616x1080 note=\"CIRAWFilter(imageURL:) returned nil\"")
        #expect(JPEGBenchRecord.format(12.3456) == "12.35")
        #expect(JPEGBenchRecord.format(0.04) == "0.04")
    }
}

@Suite("Wi-Fi routes in wording and keys")
struct WiFiRouteTests {
    @Test func bothRoutesAreCalledWiFi() {
        for route in WiFiRoute.allCases {
            #expect(CamerasWording.modeLine(.wifi(route)) == "Wi-Fi")
            let reading = BrowseWording.readingDetail(.wifi(route))
            #expect(reading.hasSuffix(".") && !reading.lowercased().contains("sony"))
        }
    }

    @Test func theRouteIsNotPartOfTheCameraKey() {
        let keys = WiFiRoute.allCases.map { route in
            CameraKeys.key(for: CameraDescriptor(id: .init(rawValue: "x"), name: "ILCE-7CM2", mode: .wifi(route)),
                           material: nil)
        }
        #expect(Set(keys).count == 1)
        #expect(keys[0].rawValue.hasPrefix("wifi-name:"))
    }

    @Test func theNewFailuresAreSaidInFinishedSentencesWithoutSonyMarks() {
        for kind in [CameraLinkFailure.Kind.identityChanged, .refused, .cardUnavailable] {
            let lines = [BrowseWording.listingFailed(kind), JPEGWording.failed(.link(CameraLinkFailure(kind)))]
            for line in lines.compactMap({ $0 }) {
                #expect(line.hasSuffix(".") && !line.lowercased().contains("sony"), "\(kind): \(line)")
            }
            #expect(ImportWording.stopReason(kind).hasSuffix("."))
        }
    }
}
