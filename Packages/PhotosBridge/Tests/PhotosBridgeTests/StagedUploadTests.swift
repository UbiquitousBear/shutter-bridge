import Foundation
import Testing
@testable import PhotosBridge

/// Reading a staged file's iCloud upload error (staging PR 7, bench S10): the quota error is 4354, in Cocoa's domain,
/// the domain the bench sheet names, or under another error; 4355 is waiting, not a problem.
@Suite("Staged uploads: reading an upload error")
struct StagedUploadTests {
    @Test func quotaFullIsCocoa4354InEitherDomainOrUnderneath() {
        #expect(UploadProblem.classify(domain: NSCocoaErrorDomain, code: 4354, underlying: nil) == .quotaFull)
        #expect(UploadProblem.classify(domain: "NSUbiquitousFileErrorDomain", code: 4354, underlying: nil)
            == .quotaFull)
        #expect(UploadProblem.classify(domain: "SomeOtherDomain", code: 1, underlying: (NSCocoaErrorDomain, 4354))
            == .quotaFull)
        #expect(UploadProblem.quotaCode == CocoaError.Code.ubiquitousFileNotUploadedDueToQuota.rawValue)
        #expect(UploadProblem.serverUnavailableCode
            == CocoaError.Code.ubiquitousFileUbiquityServerNotAvailable.rawValue)
        // 4354 in an unrelated domain is something else.
        #expect(UploadProblem.classify(domain: NSPOSIXErrorDomain, code: 4354, underlying: nil)
            == .other(domain: NSPOSIXErrorDomain, code: 4354))
    }

    @Test func serverUnavailableAndOtherErrorsAreToldApart() {
        #expect(UploadProblem.classify(domain: NSCocoaErrorDomain, code: 4355, underlying: nil) == .serverUnavailable)
        #expect(UploadProblem.classify(domain: NSCocoaErrorDomain, code: 4353, underlying: nil)
            == .other(domain: NSCocoaErrorDomain, code: 4353))
        #expect(UploadProblem.classify(domain: NSPOSIXErrorDomain, code: 28, underlying: nil)
            == .other(domain: NSPOSIXErrorDomain, code: 28))
    }

    @Test func anErrorIsReadWithTheErrorUnderIt() {
        let underlying = NSError(domain: NSCocoaErrorDomain, code: 4354)
        let top = NSError(domain: "BRCloudDocsErrorDomain", code: 35, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(UploadProblem.classify(top) == .quotaFull)
        #expect(UploadProblem.classify(NSError(domain: "BRCloudDocsErrorDomain", code: 35))
            == .other(domain: "BRCloudDocsErrorDomain", code: 35))
        #expect(NoStagedUploadReading().uploadState(of: URL(fileURLWithPath: "/nowhere")) == .unreadable)
    }
}
