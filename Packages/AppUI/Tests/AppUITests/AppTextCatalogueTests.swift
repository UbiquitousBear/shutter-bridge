import Foundation
import ImportEngine
import Testing
@testable import AppUI

/// AppUI's String Catalog against the code (I17). Every `AppText` call's key must be in
/// `Sources/AppUI/Resources/Localizable.xcstrings` with the same British English, and a counted phrase with the same
/// "one" and "other" variants, so the English the wording tests prove on Linux is what the app shows from the catalogue
/// on the iPhone. The catalogue is read from the source tree (`#filePath`), as SwiftPM on Linux doesn't bundle it.
/// `scripts/update-string-catalogue.py` brings the catalogue in step after a string is added or changed.
@Suite("String Catalog")
struct AppTextCatalogueTests {
    // MARK: The catalogue and the code

    /// Entries Xcode extracts by itself from a SwiftUI `Text` literal (no `manual` extraction state) are left alone:
    /// they aren't `AppText`'s, and a local build may add them.
    @Test("The catalogue is British English, with a translated en-GB value for every entry AppText keeps")
    func catalogueShape() throws {
        let catalogue = try Catalogue.load()
        #expect(catalogue.sourceLanguage == "en-GB")
        #expect(catalogue.version == "1.0")
        #expect(!catalogue.entries.isEmpty)
        for (key, entry) in catalogue.entries where entry.isManual {
            switch entry.value {
            case let .string(unit):
                #expect(unit.state == "translated", "\(key)")
                #expect(!unit.value.isEmpty, "\(key)")
            case let .plural(one, other):
                #expect(one.state == "translated" && other.state == "translated", "\(key)")
            case nil:
                Issue.record("\(key) has no en-GB value")
            }
        }
    }

    @Test("Every key the code uses is in the catalogue with the code's English")
    func everyKeyIsInTheCatalogue() throws {
        let catalogue = try Catalogue.load()
        let uses = try SourceKeys.scan()
        #expect(uses.count > 300, "the scan found \(uses.count) keys: it may have stopped early")
        for use in uses {
            guard let entry = catalogue.entries[use.key] else {
                Issue.record("\(use.file): \"\(use.key)\" isn't in Localizable.xcstrings")
                continue
            }
            // Xcode marks a string it can't find in the code as stale unless it is managed by hand.
            #expect(entry.isManual, "\(use.file): \"\(use.key)\" needs the manual extraction state")
            switch (use.kind, entry.value) {
            case (.string, .string(let unit)?), (.format, .string(let unit)?):
                #expect(unit.value == use.key, "\(use.file): \"\(use.key)\" reads \"\(unit.value)\" in the catalogue")
            case let (.counted(one), .plural(catalogueOne, catalogueOther)?):
                #expect(catalogueOne.value == one, "\(use.file): \"\(use.key)\"'s one is \"\(catalogueOne.value)\"")
                #expect(catalogueOther.value == use.key, "\(use.file): \"\(use.key)\"'s other is \"\(catalogueOther.value)\"")
            default:
                Issue.record("\(use.file): \"\(use.key)\" is \(use.kind) in the code but not in the catalogue")
            }
        }
    }

    @Test("Every catalogue entry is used, and a key is used one way")
    func noStaleEntries() throws {
        let catalogue = try Catalogue.load()
        let uses = try SourceKeys.scan()
        let used = Set(uses.map(\.key))
        for (key, entry) in catalogue.entries where entry.isManual && !used.contains(key) {
            Issue.record("\"\(key)\" is in Localizable.xcstrings but no AppText call uses it")
        }
        let byKey = Dictionary(grouping: uses, by: \.key)
        for (key, group) in byKey where Set(group.map(\.kind)).count > 1 {
            Issue.record("\"\(key)\" is used in more than one way: \(group.map { "\($0.file) \($0.kind)" })")
        }
    }

    @Test("Placeholders: one %lld in each plural variant, %@ only in formats")
    func placeholders() throws {
        for use in try SourceKeys.scan() {
            switch use.kind {
            case .string:
                #expect(!use.key.contains("%@") && !use.key.contains("%lld"), "\(use.file): \"\(use.key)\" needs format")
            case .format:
                #expect(use.key.contains("@"), "\(use.file): \"\(use.key)\" has no argument: use string")
                #expect(!use.key.contains("%lld"), "\(use.file): \"\(use.key)\": counts go through counted")
            case let .counted(one):
                for variant in [one, use.key] {
                    #expect(variant.components(separatedBy: "%lld").count == 2, "\(use.file): \"\(variant)\"")
                    #expect(!variant.contains("%@"), "\(use.file): \"\(variant)\" takes the count only")
                }
            }
        }
    }

    // MARK: The counted words the backlog names (section 9)

    @Test("Plural variants for files and photos, in the catalogue and in the words")
    func countedWords() throws {
        let catalogue = try Catalogue.load()
        let expected: [(other: String, one: String)] = [
            ("%lld files", "%lld file"), ("%lld photos", "%lld photo"), ("%lld new photos", "%lld new photo"),
            ("%lld stars", "%lld star"), ("%lld rejected files left out. Pick them in Browse to import them anyway.",
                                         "%lld rejected file left out. Pick it in Browse to import it anyway."),
        ]
        for (other, one) in expected {
            guard case let .plural(catalogueOne, catalogueOther)? = catalogue.entries[other]?.value else {
                Issue.record("\"\(other)\" has no plural variants")
                continue
            }
            #expect(catalogueOne.value == one)
            #expect(catalogueOther.value == other)
        }
        #expect(ByteWording.files(1) == "1 file")
        #expect(ByteWording.files(3) == "3 files")
        #expect(ByteWording.files(0) == "0 files")
        #expect(KeepersWording.photos(1) == "1 photo")
        #expect(KeepersWording.photos(48) == "48 photos")
        #expect(NewPhotosWording.newPhotos(1) == "1 new photo")
        #expect(NewPhotosWording.newPhotos(12) == "12 new photos")
        #expect(CullWording.stars(1) == "1 star")
        #expect(CullWording.stars(4) == "4 stars")
    }

    // MARK: AppText itself

    @Test("Arguments go in by position or in order, and %% is a percent sign")
    func substitution() {
        #expect(AppText.substitute("%@ of %@", ["1.2 GB", "4.5 GB"]) == "1.2 GB of 4.5 GB")
        #expect(AppText.substitute("%2$@, then %1$@", ["first", "second"]) == "second, then first")
        #expect(AppText.substitute("Battery %@%%", ["80"]) == "Battery 80%")
        #expect(AppText.substitute("%@ and %@", ["only"]) == "only and ")
        #expect(AppText.substitute("100 %", []) == "100 %")
        #expect(AppText.substitute("%lld files", []) == "%lld files")
        #expect(AppText.format("%@ free", "1.2 GB") == "1.2 GB free")
        #expect(AppText.string("Cameras") == "Cameras")
        #expect(AppText.counted(1, one: "%lld file", other: "%lld files") == "1 file")
        #expect(AppText.counted(2, one: "%lld file", other: "%lld files") == "2 files")
    }

    /// Counts are plain digits, as before the catalogue and as every other number in the copy, so a sentence never
    /// mixes "1500" with "2,000".
    @Test("A count of a thousand or more is written in plain digits, like the numbers around it")
    func largeCountsArePlainDigits() {
        #expect(ByteWording.files(1234) == "1234 files")
        #expect(KeepersWording.photos(12_345) == "12345 photos")
        let progress = ImportProgress(filesDone: 1500, filesTotal: 2000, bytesDone: 0, bytesTotal: 0, state: .running)
        #expect(ImportWording.status(progress) == "1500 of 2000 files done")
    }

    // The catalogue as Xcode compiles it into `Bundle.module`: CI's iOS Simulator run. SwiftPM's own build system on a
    // Mac copies a String Catalog as it is rather than compiling it, so `swift test` there would find no compiled key.
    #if os(iOS)
    /// Every key must be found in the compiled catalogue (a miss falls back to the code's English without a sound), the
    /// plural variants must choose, and the number stays in plain digits.
    @Test("The compiled catalogue has every key, and its plural variants choose")
    func compiledCatalogue() throws {
        for use in try SourceKeys.scan() {
            #expect(AppText.catalogueHas(use.key), "\(use.file): \"\(use.key)\" isn't in the compiled catalogue")
        }
        #expect(AppText.counted(1, one: "%lld file", other: "%lld files") == "1 file")
        #expect(AppText.counted(3, one: "%lld file", other: "%lld files") == "3 files")
        #expect(AppText.counted(0, one: "%lld file", other: "%lld files") == "0 files")
        #expect(AppText.counted(1, one: "%lld photo", other: "%lld photos") == "1 photo")
        #expect(AppText.counted(1234, one: "%lld file", other: "%lld files") == "1234 files")
        #expect(AppText.counted(1, one: "%lld rejected file left out. Pick it in Browse to import it anyway.",
                                other: "%lld rejected files left out. Pick them in Browse to import them anyway.")
            == "1 rejected file left out. Pick it in Browse to import it anyway.")
    }
    #endif
}

// MARK: - Reading the catalogue

/// The parts of `Localizable.xcstrings` the tests read.
private struct Catalogue {
    struct Unit {
        var state: String
        var value: String
    }

    enum Value {
        case string(Unit)
        case plural(one: Unit, other: Unit)
    }

    struct Entry {
        var extractionState: String?
        var value: Value?

        /// Kept by `AppText` (and `scripts/update-string-catalogue.py`), not extracted by Xcode.
        var isManual: Bool { extractionState == "manual" }
    }

    var sourceLanguage: String
    var version: String
    var entries: [String: Entry]

    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AppUI
            .appending(path: "Sources/AppUI/Resources/Localizable.xcstrings")
    }

    static func load() throws -> Catalogue {
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        var entries: [String: Entry] = [:]
        for (key, raw) in strings {
            let object = raw as? [String: Any] ?? [:]
            let localization = (object["localizations"] as? [String: Any])?["en-GB"] as? [String: Any]
            entries[key] = Entry(extractionState: object["extractionState"] as? String,
                                 value: localization.flatMap(value(of:)))
        }
        return Catalogue(sourceLanguage: root["sourceLanguage"] as? String ?? "",
                         version: root["version"] as? String ?? "", entries: entries)
    }

    private static func value(of localization: [String: Any]) -> Value? {
        if let unit = unit(localization["stringUnit"]) { return .string(unit) }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any]
        guard let plural, let one = unit((plural["one"] as? [String: Any])?["stringUnit"]),
              let other = unit((plural["other"] as? [String: Any])?["stringUnit"]) else { return nil }
        return .plural(one: one, other: other)
    }

    private static func unit(_ raw: Any?) -> Unit? {
        guard let object = raw as? [String: Any], let value = object["value"] as? String else { return nil }
        return Unit(state: object["state"] as? String ?? "", value: value)
    }
}

// MARK: - Finding the keys in the source

/// Every `AppText.string("…")`, `AppText.format("…", …)` and `AppText.counted(n, one: "…", other: "…")` in
/// `Sources/AppUI`, with its key: a string literal, or literals joined with `+`. A key built any other way fails the
/// scan, so no string escapes the check. The same rules as `scripts/update-string-catalogue.py`.
private enum SourceKeys {
    enum Kind: Hashable, CustomStringConvertible {
        case string, format
        case counted(one: String)

        var description: String {
            switch self {
            case .string: "string"
            case .format: "format"
            case .counted: "counted"
            }
        }
    }

    struct Use {
        var file: String
        var key: String
        var kind: Kind
    }

    struct ScanError: Error, CustomStringConvertible {
        var description: String
    }

    static func scan() throws -> [Use] {
        let sources = Catalogue.url.deletingLastPathComponent().deletingLastPathComponent()
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw ScanError(description: "can't read \(sources.path)")
        }
        var uses: [Use] = []
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        for file in files where file.lastPathComponent != "AppText.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Comments are left out, so documentation examples aren't taken for keys.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
                .joined(separator: "\n")
            do {
                uses += try calls(in: Array(code)).map { Use(file: file.lastPathComponent, key: $0.key, kind: $0.kind) }
            } catch let error as ScanError {
                throw ScanError(description: "\(file.lastPathComponent): \(error.description)")
            }
        }
        return uses
    }

    private static func calls(in source: [Character]) throws -> [(key: String, kind: Kind)] {
        let marker = Array("AppText.")
        var found: [(String, Kind)] = []
        var index = 0
        while index + marker.count < source.count {
            guard Array(source[index ..< index + marker.count]) == marker else {
                index += 1
                continue
            }
            index += marker.count
            let rest = String(source[index ..< min(index + 8, source.count)])
            if rest.hasPrefix("string(") || rest.hasPrefix("format(") {
                let kind: Kind = rest.hasPrefix("string(") ? .string : .format
                let (key, end) = try chain(source, from: index + 7)
                found.append((key, kind))
                index = end
            } else if rest.hasPrefix("counted(") {
                guard let oneAt = find(Array("one:"), in: source, from: index) else {
                    throw ScanError(description: "a counted phrase without one:")
                }
                let (one, afterOne) = try chain(source, from: oneAt + 4)
                var at = skipSpace(source, afterOne)
                guard at < source.count, source[at] == "," else { throw ScanError(description: "expected , other:") }
                at = skipSpace(source, at + 1)
                guard String(source[at ..< min(at + 6, source.count)]) == "other:" else {
                    throw ScanError(description: "expected other: after one:")
                }
                let (other, end) = try chain(source, from: at + 6)
                found.append((other, .counted(one: one)))
                index = end
            }
        }
        return found
    }

    private static func find(_ needle: [Character], in source: [Character], from start: Int) -> Int? {
        var index = start
        while index + needle.count <= source.count {
            if Array(source[index ..< index + needle.count]) == needle { return index }
            index += 1
        }
        return nil
    }

    private static func skipSpace(_ source: [Character], _ start: Int) -> Int {
        var index = start
        while index < source.count, source[index].isWhitespace { index += 1 }
        return index
    }

    /// String literals joined by `+`, as one key.
    private static func chain(_ source: [Character], from start: Int) throws -> (String, Int) {
        var parts: [String] = []
        var index = start
        while true {
            index = skipSpace(source, index)
            guard index < source.count, source[index] == "\"" else {
                throw ScanError(description: "a key must be a string literal")
            }
            let (value, end) = try literal(source, from: index)
            parts.append(value)
            let next = skipSpace(source, end)
            if next < source.count, source[next] == "+" {
                index = next + 1
                continue
            }
            return (parts.joined(), end)
        }
    }

    /// One single-line string literal starting at its opening quote; no interpolation allowed.
    private static func literal(_ source: [Character], from start: Int) throws -> (String, Int) {
        var value = ""
        var index = start + 1
        while index < source.count {
            let character = source[index]
            switch character {
            case "\"":
                return (value, index + 1)
            case "\n":
                throw ScanError(description: "an unterminated string literal")
            case "\\":
                guard index + 1 < source.count else { throw ScanError(description: "a stray backslash") }
                let escaped = source[index + 1]
                switch escaped {
                case "(":
                    throw ScanError(description: "a key may not interpolate: use AppText.format with %@")
                case "u":
                    guard let close = source[index...].firstIndex(of: "}"),
                          let scalar = UInt32(String(source[(index + 3) ..< close]), radix: 16).flatMap(Unicode.Scalar.init)
                    else { throw ScanError(description: "a bad \\u{…} escape") }
                    value.unicodeScalars.append(scalar)
                    index = close + 1
                case "n": value.append("\n"); index += 2
                case "t": value.append("\t"); index += 2
                case "0": value.append("\0"); index += 2
                case "r": value.append("\r"); index += 2
                default: value.append(escaped); index += 2
                }
            default:
                value.append(character)
                index += 1
            }
        }
        throw ScanError(description: "an unterminated string literal")
    }
}
