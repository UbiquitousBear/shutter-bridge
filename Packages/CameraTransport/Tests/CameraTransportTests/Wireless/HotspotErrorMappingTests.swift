import Foundation
import Testing
@testable import CameraTransport
#if canImport(NetworkExtension) && os(iOS)
import NetworkExtension
#endif

// The pure half of `NEHotspotJoiner` (W12), tested on Linux. The adapter itself is compiled by CI's Xcode 27 job and
// checked on the bench iPhone; the last suite runs only there, in the iOS Simulator, against the SDK's own values.

@Suite("Hotspot errors to join failures")
struct HotspotErrorMappingTests {
    private typealias Code = HotspotErrorMapping.Code

    private func failure(_ code: Code) -> JoinFailure? {
        HotspotErrorMapping.failure(domain: HotspotErrorMapping.domain, code: code.rawValue)
    }

    @Test func alreadyAssociatedIsSuccess() {
        #expect(failure(.alreadyAssociated) == nil)
    }

    @Test func theTwoPausesKeepTheirMeaning() {
        // The session pauses on these (`.joinDeclined` and `.needsJoin`) instead of trying again.
        #expect(failure(.userDenied) == .userDenied)
        #expect(failure(.applicationIsNotInForeground) == .notInForeground)
    }

    @Test func refusedDetailsAreInvalidCredentials() {
        #expect(failure(.invalid) == .invalidCredentials)
        #expect(failure(.invalidSSID) == .invalidCredentials)
        #expect(failure(.invalidWPAPassphrase) == .invalidCredentials)
    }

    @Test func pendingAndSystemFailuresAreCountedTries() {
        #expect(failure(.pending) == .pending)
        #expect(failure(.systemConfiguration) == .systemConfiguration)
        #expect(failure(.internalError) == .systemConfiguration)
    }

    @Test func everythingElseInTheDomainKeepsItsCode() {
        let others: [Code] = [
            .invalidWEPPassphrase, .invalidEAPSettings, .invalidHS20Settings, .invalidHS20DomainName, .unknown,
            .joinOnceNotSupported, .invalidSSIDPrefix,
        ]
        for code in others {
            #expect(failure(code) == .other(code.rawValue), "\(code)")
        }
    }

    @Test func everyCodeIsMappedOnce() {
        // Only "already associated" is success; every other case is a failure.
        let successes = Code.allCases.filter { failure($0) == nil }
        #expect(successes == [.alreadyAssociated])
        #expect(Code.allCases.count == 16)
        #expect(Code.allCases.map(\.rawValue) == Array(0 ... 15))
    }

    @Test func aCodeAddedAfterIOS27IsAFailedTry() {
        #expect(HotspotErrorMapping.failure(domain: HotspotErrorMapping.domain, code: 16) == .other(16))
        #expect(HotspotErrorMapping.failure(domain: HotspotErrorMapping.domain, code: -1) == .other(-1))
    }

    @Test func anotherDomainIsNeverSuccessNorAPause() {
        // The same numbers in another domain mean something else: 13 is not "already associated" there, nor 7 "declined".
        for code in [7, 13, 14, 1] {
            #expect(HotspotErrorMapping.failure(domain: NSCocoaErrorDomain, code: code) == .other(code))
        }
        #expect(HotspotErrorMapping.failure(domain: NSPOSIXErrorDomain, code: 50) == .other(50))
    }
}

#if canImport(NetworkExtension) && os(iOS)
/// Runs only in CI's iOS Simulator job: the raw values above are the SDK's.
@Suite("Hotspot error codes match NetworkExtension")
struct HotspotErrorCodesMatchSDKTests {
    @Test func domainIsTheSDKs() {
        #expect(HotspotErrorMapping.domain == NEHotspotConfigurationErrorDomain)
    }

    @Test func rawValuesAreTheSDKs() {
        let pairs: [(HotspotErrorMapping.Code, NEHotspotConfigurationError)] = [
            (.invalid, .invalid),
            (.invalidSSID, .invalidSSID),
            (.invalidWPAPassphrase, .invalidWPAPassphrase),
            (.invalidWEPPassphrase, .invalidWEPPassphrase),
            (.invalidEAPSettings, .invalidEAPSettings),
            (.invalidHS20Settings, .invalidHS20Settings),
            (.invalidHS20DomainName, .invalidHS20DomainName),
            (.userDenied, .userDenied),
            (.internalError, .internal),
            (.pending, .pending),
            (.systemConfiguration, .systemConfiguration),
            (.unknown, .unknown),
            (.joinOnceNotSupported, .joinOnceNotSupported),
            (.alreadyAssociated, .alreadyAssociated),
            (.applicationIsNotInForeground, .applicationIsNotInForeground),
            (.invalidSSIDPrefix, .invalidSSIDPrefix),
        ]
        #expect(pairs.count == HotspotErrorMapping.Code.allCases.count)
        for (ours, sdk) in pairs {
            #expect(ours.rawValue == sdk.rawValue, "\(ours)")
        }
    }

    @Test func anNSErrorFromTheSDKMapsByItsDomainAndCode() {
        let declined = NSError(domain: NEHotspotConfigurationErrorDomain,
                               code: NEHotspotConfigurationError.userDenied.rawValue)
        #expect(HotspotErrorMapping.failure(domain: declined.domain, code: declined.code) == .userDenied)
        let already = NSError(domain: NEHotspotConfigurationErrorDomain,
                              code: NEHotspotConfigurationError.alreadyAssociated.rawValue)
        #expect(HotspotErrorMapping.failure(domain: already.domain, code: already.code) == nil)
    }

    @Test func adapterIsUsableAsHotspotJoining() async {
        // Leaving with an empty name never calls NetworkExtension (the simulator run has no entitlement), so this only
        // proves the adapter builds and is usable as the session's `HotspotJoining`.
        let joiner: any HotspotJoining = NEHotspotJoiner()
        await joiner.leave(ssid: "")
    }
}
#endif
