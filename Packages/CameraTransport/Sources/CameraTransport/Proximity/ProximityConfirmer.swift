// The confirmation after every wake (backlog section 11, decision 8, decided): is the peripheral that woke the app really one of
// the app's cameras? The only thing the camera advertises that iOS can filter a background scan on is service 1800, which isn't
// Sony's (Generic Access), so anything advertising it can wake the app. Pure, tested on Linux.

import BLEKit
import Foundation

/// Decides whether a proximity report is one of the app's cameras, and which.
///
/// 1. **The stored peripheral identifier.** iOS gives the camera the same identifier in every scan, for this app (measured
///    across reconnects and camera restarts, 5 Nov), so a match is the camera, whatever the advertisement says.
/// 2. **Sony's company ID together with a camera's name**, for a camera with no stored identifier (one only ever used over
///    USB, say): company 0x012D at the front of the manufacturer data, a name with "ILCE" or "SONY" in it
///    (`SonyAdvertisement.nameLooksLikeCamera`), and, when the camera's model is known, that model in the name as a whole
///    word ("ILCE-7C", the α7C, isn't in "ILCE-7CM2", the α7C II), a name that is exactly the model winning. If more than
///    one camera fits equally, none is chosen.
///
/// Anything else that advertises 1800 is ignored (nil), without a reminder. A camera that has a stored identifier is never
/// matched by the second rule: another identifier is another camera body (a friend's α7C II, say). Nothing here logs the
/// manufacturer data, the name or the identifier.
public struct ProximityConfirmer: Sendable {
    /// How a report was confirmed, for the log.
    public enum Match: Sendable, Equatable, CustomStringConvertible {
        case storedIdentifier
        case companyAndName

        public var description: String {
            switch self {
            case .storedIdentifier: "stored identifier"
            case .companyAndName: "company ID and name"
            }
        }
    }

    public struct Confirmation: Sendable, Equatable {
        public let camera: KnownCamera
        public let match: Match

        public init(camera: KnownCamera, match: Match) {
            self.camera = camera
            self.match = match
        }
    }

    /// The cameras reports are confirmed against.
    public let known: [KnownCamera]

    public init(known: [KnownCamera]) {
        self.known = known
    }

    /// The camera `report` is, and how that was decided; nil when it isn't one of the app's cameras.
    public func confirm(_ report: ProximityReport) -> Confirmation? {
        confirm(peripheral: report.peripheral, advertisement: report.advertisement, name: report.name)
    }

    /// The camera a peripheral with this advertisement and name is, and how that was decided; nil when it isn't one of the
    /// app's cameras.
    public func confirm(peripheral: PeripheralID, advertisement: SonyAdvertisement?, name: String?) -> Confirmation? {
        if let camera = known.first(where: { $0.peripheral == peripheral }) {
            return Confirmation(camera: camera, match: .storedIdentifier)
        }
        guard let advertisement, advertisement.isSony, SonyAdvertisement.nameLooksLikeCamera(name), let name else {
            return nil
        }
        let upperName = name.uppercased()
        let unidentified = known.filter { $0.peripheral == nil }
        // A name that is exactly the camera's model beats one with the model as a word in it, which beats a camera whose model
        // isn't known yet; within the best group that isn't empty, exactly one.
        let byModel = unidentified.filter { !$0.model.isEmpty && Self.name(upperName, hasWord: $0.model.uppercased()) }
        let exact = byModel.filter { $0.model.uppercased() == upperName }
        let modelUnknown = unidentified.filter { $0.model.isEmpty }
        let group = !exact.isEmpty ? exact : !byModel.isEmpty ? byModel : modelUnknown
        guard group.count == 1, let camera = group.first else { return nil }
        return Confirmation(camera: camera, match: .companyAndName)
    }

    /// Whether `word` is in `name` with no letter or digit either side of it: "ILCE-7CM2" has "ILCE-7CM2" but not "ILCE-7C"
    /// or "ILCE-7". `word` isn't empty.
    static func name(_ name: String, hasWord word: String) -> Bool {
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        var from = name.startIndex
        while from < name.endIndex, let found = name.range(of: word, range: from..<name.endIndex) {
            let startsWord = found.lowerBound == name.startIndex || !isWordCharacter(name[name.index(before: found.lowerBound)])
            let endsWord = found.upperBound == name.endIndex || !isWordCharacter(name[found.upperBound])
            if startsWord, endsWord { return true }
            from = name.index(after: found.lowerBound)
        }
        return false
    }
}
