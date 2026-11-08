import CameraTransport
import Foundation
import Testing
@testable import AppUI

@Suite("Copy as JPEG: which file, and what is done to it")
struct JPEGSourceRuleTests {
    @Test func aLoneJPGIsUsedAsItIs() throws {
        let jpg = item("DSC00001.JPG")
        let source = try #require(JPEGSourceRule(listing: [jpg]).source(for: jpg))
        #expect(source.kind == .jpegAsIs)
        #expect(source.fetched == jpg)
        #expect(source.conversion == .asIs)
    }

    @Test func aRAWWithItsPairJPGUsesTheJPGAsItIs() throws {
        let raw = item("DSC00002.ARW", at: 10)
        let jpg = item("dsc00002.jpg", at: 10.4)   // stems compare case-insensitively
        let source = try #require(JPEGSourceRule(listing: [jpg, raw]).source(for: raw))
        #expect(source.kind == .pairedJPEG)
        #expect(source.fetched == jpg)
        #expect(source.pressed == raw)
        #expect(source.conversion == .asIs)
    }

    @Test func pressingTheJPGHalfOfAPairUsesThatJPG() throws {
        let raw = item("DSC00002.ARW", at: 10)
        let jpg = item("DSC00002.JPG", at: 10)
        let source = try #require(JPEGSourceRule(listing: [raw, jpg]).source(for: jpg))
        #expect(source.kind == .jpegAsIs)
        #expect(source.fetched == jpg)
    }

    @Test func aRAWAloneIsRendered() throws {
        let raw = item("DSC00003.ARW")
        let source = try #require(JPEGSourceRule(listing: [raw, item("DSC00004.JPG")]).source(for: raw))
        #expect(source.kind == .rawRender)
        #expect(source.fetched == raw)
        #expect(source.conversion == .renderRAW)
    }

    @Test func noPairAcrossFoldersOrBeyondOneSecondOrWithoutADate() {
        let raw = item("DSC00005.ARW", folder: "DCIM/100MSDCF", at: 0)
        let otherFolder = item("DSC00005.JPG", folder: "DCIM/101MSDCF", at: 0)
        let tooLate = item("DSC00005.JPG", folder: "DCIM/100MSDCF", at: 1.5)
        #expect(JPEGSourceRule(listing: [raw, otherFolder]).source(for: raw)?.kind == .rawRender)
        #expect(JPEGSourceRule(listing: [raw, tooLate]).source(for: raw)?.kind == .rawRender)

        let undatedRAW = item("DSC00006.ARW", at: nil)
        let jpg = item("DSC00006.JPG", at: 0)
        #expect(JPEGSourceRule(listing: [undatedRAW, jpg]).source(for: undatedRAW)?.kind == .rawRender)
        let raw6 = item("DSC00006.ARW", at: 0)
        let undatedJPG = item("DSC00006.JPG", at: nil)
        #expect(JPEGSourceRule(listing: [raw6, undatedJPG]).source(for: raw6)?.kind == .rawRender)
    }

    @Test func theClosestJPGWinsAndExactlyOneSecondStillPairs() {
        let raw = item("DSC00007.ARW", at: 100)
        let far = item("DSC00007.JPG", at: 101, id: "far")
        let near = item("DSC00007.JPG", at: 100.2, id: "near")
        #expect(JPEGSourceRule(listing: [far, near, raw]).pairedJPEG(of: raw) == near)
        #expect(JPEGSourceRule(listing: [far, raw]).pairedJPEG(of: raw) == far)
    }

    @Test func aRAWWhosePartnerIsAHIFIsRenderedFromTheRAW() {
        // Only a JPG pair counts (Shamil, 8 Nov); a RAW+HEIF pair is an open point.
        let raw = item("DSC00008.ARW")
        let hif = item("DSC00008.HIF")
        #expect(JPEGSourceRule(listing: [raw, hif]).source(for: raw)?.kind == .rawRender)
    }

    @Test func aHEIFIsReencoded() throws {
        let hif = item("DSC00009.HIF")
        let source = try #require(JPEGSourceRule(listing: [hif]).source(for: hif))
        #expect(source.kind == .heifReencode)
        #expect(source.conversion == .reencodeHEIF)
    }

    @Test func videoAndSidecarsOfferNothing() {
        let rule = JPEGSourceRule(listing: [])
        #expect(rule.source(for: item("C0001.MP4")) == nil)
        #expect(rule.source(for: item("C0001M01.XML")) == nil)
        #expect(rule.source(for: item("README")) == nil)
    }

    @Test func stems() {
        #expect(JPEGSourceRule.stem(of: "DSC00001.ARW") == "DSC00001")
        #expect(JPEGSourceRule.stem(of: "archive.tar.gz") == "archive.tar")
        #expect(JPEGSourceRule.stem(of: "NOEXT") == "NOEXT")
        #expect(JPEGSourceRule.stem(of: ".hidden") == ".hidden")
    }

    @Test func pathsForTheLog() {
        #expect(JPEGPath(.rawRender, usedEmbeddedPreview: true) == .previewFallback)
        #expect(JPEGPath(.rawRender, usedEmbeddedPreview: false) == .rawRender)
        #expect(JPEGPath(.pairedJPEG, usedEmbeddedPreview: false).rawValue == "pair-jpg")
        #expect(JPEGPath(.jpegAsIs, usedEmbeddedPreview: false).rawValue == "jpg-as-is")
        #expect(JPEGPath(.heifReencode, usedEmbeddedPreview: false).rawValue == "heif-reencode")
    }
}
