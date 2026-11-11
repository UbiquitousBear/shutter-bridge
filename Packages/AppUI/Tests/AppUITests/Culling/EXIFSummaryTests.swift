import Catalogue
import Foundation
import Testing
@testable import AppUI

@Suite("EXIF line")
struct EXIFSummaryTests {
    let full: [String: Any] = [
        "DateTimeOriginal": "2026:11:05 14:03:22", "ExposureTime": 0.004, "FNumber": 2.8,
        "ISOSpeedRatings": [400], "FocalLength": 35.0,
    ]

    @Test func theLineReadsLeftToRight() {
        let summary = EXIFSummary(imageProperties: full)
        #expect(summary.line == "14:03:22 · 1/250 s · f/2.8 · ISO 400 · 35 mm")
        #expect(summary.captureDate == CaptureDate(rawValue: "20261105T140322"))
        #expect(summary.iso == 400 && summary.shutterSeconds == 0.004)
    }

    @Test func imageIOPutsTheFieldsInsideAnExifDictionary() {
        #expect(EXIFSummary(imageProperties: ["{Exif}": full, "PixelWidth": 6000]).line
            == "14:03:22 · 1/250 s · f/2.8 · ISO 400 · 35 mm")
    }

    @Test func slowShuttersAreInSecondsAndWholeNumbersLoseTheirDecimal() {
        #expect(EXIFSummary(shutterSeconds: 2).line == "2 s")
        #expect(EXIFSummary(shutterSeconds: 1.3).line == "1.3 s")
        #expect(EXIFSummary(shutterSeconds: 0.5).line == "0.5 s")
        #expect(EXIFSummary(shutterSeconds: 1.0 / 30).line == "1/30 s")
        #expect(EXIFSummary(shutterSeconds: 1.0 / 8000).line == "1/8000 s")
        #expect(EXIFSummary(aperture: 4.0, focalLengthMM: 24).line == "f/4 · 24 mm")
        #expect(EXIFSummary(aperture: 1.8, focalLengthMM: 28.5).line == "f/1.8 · 28.5 mm")
    }

    @Test func missingOrUnusableValuesAreLeftOut() {
        let summary = EXIFSummary(imageProperties: [
            "ExposureTime": "fast", "FNumber": 0, "ISOSpeedRatings": [Int](), "FocalLength": -5.0,
            "DateTimeOriginal": "yesterday",
        ])
        #expect(summary.isEmpty && summary.line == "")
        #expect(EXIFSummary(imageProperties: [:]).isEmpty)
        #expect(EXIFSummary(imageProperties: ["ExposureTime": Double.nan, "FNumber": Double.infinity]).isEmpty)
        #expect(EXIFSummary(imageProperties: ["ISOSpeedRatings": 100, "FNumber": 5]).line == "f/5 · ISO 100")
    }

    @Test func aDateThatIsntADateIsLeftOut() {
        #expect(EXIFSummary.captureDate(fromExif: "2026:13:45 25:61:61") == nil)
        #expect(EXIFSummary.captureDate(fromExif: "2026:11:05 14:03:22") != nil)
    }
}
