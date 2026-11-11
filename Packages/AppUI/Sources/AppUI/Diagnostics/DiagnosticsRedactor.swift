import Foundation

/// Takes private values out of a line of text before it goes into the diagnostics file (backlog section 6, "Redaction by
/// construction and by test"). The app's own log lines are written to hold names, sizes and times only, so this is the
/// second lock: it runs over every line of the archive, whatever put it there.
///
/// Replaced, case-insensitively where letters matter:
/// - every value the app says is private (`privateValues`: the stored network name, the cameras' serial numbers, the
///   PTP/IP GUID, a peripheral's identifier), wherever it appears, even inside a longer word;
/// - anything shaped like a UUID (the PTP/IP GUID, a peripheral identifier, a device identifier);
/// - a MAC address (six pairs of hex digits joined by colons or hyphens), and 12 hex digits in a row (the camera's
///   hardware ID, the tail of its SSDP UDN);
/// - an IPv6 address (eight groups, or any with "::");
/// - an IPv4 address other than the camera's fixed gateway, 192.168.122.1, which is the same on every α7C II and which the
///   bench lines name on purpose.
///
/// What it leaves alone: anything else, including numbers, times, sizes and camera and firmware names. Matching is
/// deliberately broad: a run of 12 hex digits is replaced even when it is only a number, because a diagnostics file with
/// a missing number is better than one with a hardware ID.
public struct DiagnosticsRedactor: Sendable {
    /// The camera's fixed gateway on its own network; the only address that stays.
    public static let cameraGateway = "192.168.122.1"

    /// What stands in for each kind of value. None of these matches any of the patterns above.
    public static let privateValueMark = "[private value removed]"
    public static let identifierMark = "[identifier removed]"
    public static let addressMark = "[address removed]"

    /// The values to remove wherever they appear, longest first so a value holding another is removed whole.
    private let privateValues: [String]

    /// Empty values are ignored; they would match everywhere.
    public init(privateValues: [String] = []) {
        var seen = Set<String>()
        self.privateValues = privateValues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.count > $1.count }
    }

    /// The text with every private value, identifier and address removed.
    public func redact(_ text: String) -> String {
        var result = Self.removing(privateValues, from: text, with: Self.privateValueMark)
        result = Self.replaceMatches(of: Self.uuid, in: result) { _ in Self.identifierMark }
        result = Self.replaceMatches(of: Self.macAddress, in: result) { _ in Self.identifierMark }
        result = Self.replaceMatches(of: Self.twelveHexDigits, in: result) { _ in Self.identifierMark }
        result = Self.replaceMatches(of: Self.ipv6, in: result) { _ in Self.addressMark }
        result = Self.replaceMatches(of: Self.ipv4, in: result) { match in
            match == Self.cameraGateway ? match : Self.addressMark
        }
        return result
    }

    // MARK: Patterns

    private static let uuid = pattern(#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#)
    private static let macAddress = pattern(#"(?<![0-9A-Fa-f])[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}(?![0-9A-Fa-f])"#)
    private static let twelveHexDigits = pattern(#"(?<![0-9A-Za-z])[0-9A-Fa-f]{12}(?![0-9A-Za-z])"#)
    // Eight groups, or a shorter run containing "::" (which a time such as 10:20:30 never has).
    private static let ipv6 = pattern(
        #"(?<![0-9A-Fa-f:])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{0,4}::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{0,4})(?![0-9A-Fa-f:])"#)
    private static let ipv4 = pattern(#"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9]|\.[0-9])"#)

    /// Built once. A pattern that doesn't compile is a bug found by the first test, never by a user's data.
    private static func pattern(_ source: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: source)
        } catch {
            preconditionFailure("DiagnosticsRedactor: pattern \(source) does not compile: \(error)")
        }
    }

    private static func replaceMatches(
        of expression: NSRegularExpression, in text: String, with replacement: (String) -> String
    ) -> String {
        let whole = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: whole)
        guard !matches.isEmpty else { return text }
        var result = text
        // From the end, so the earlier ranges stay valid.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(String(result[range])))
        }
        return result
    }

    /// Replaces every occurrence of every value in one pass over the original text, so a value that happens to be a word
    /// in a mark ("value") can't be found inside a mark put there a moment ago. Overlapping occurrences become one mark.
    private static func removing(_ values: [String], from text: String, with mark: String) -> String {
        var ranges: [Range<String.Index>] = []
        for value in values {
            var from = text.startIndex
            while from < text.endIndex,
                  let found = text.range(of: value, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: from..<text.endIndex) {
                ranges.append(found)
                from = found.upperBound
            }
        }
        guard !ranges.isEmpty else { return text }
        ranges.sort { $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound > $1.upperBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var result = text
        for range in merged.reversed() { result.replaceSubrange(range, with: mark) }
        return result
    }
}
