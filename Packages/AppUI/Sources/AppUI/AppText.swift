import Foundation

/// AppUI's user-facing strings, looked up in its String Catalog (`Resources/Localizable.xcstrings`, source language
/// British English; I17). Every key is the string's own British English text, as String Catalogs key them, so what
/// the code says is what the catalogue holds: `AppText.string("Cameras")`, `AppText.format("%@ free", size)`, and a
/// counted phrase, whose key is its "other" form and whose catalogue entry has the plural variants
/// (`AppText.counted(n, one: "%lld file", other: "%lld files")`).
///
/// - **On Apple platforms** the strings come from `Bundle.module`, where Xcode (and SwiftPM on a Mac) compiles the
///   catalogue. A key the catalogue doesn't have falls back to the English the code gives, so the text never changes
///   if a lookup misses; `AppTextCatalogueTests` checks in CI that none does.
/// - **On Linux** the catalogue isn't processed (`Package.swift` leaves it out there: SwiftPM has no rule for it and
///   would warn), and the English the code gives is the text. `AppTextCatalogueTests` reads the catalogue's JSON and
///   checks that every key the code uses is in it with the same British English and, for a counted phrase, the same
///   "one" and "other" variants, so the wording tests on Linux prove what the app shows.
///
/// Keys are always string literals (joined with `+` where a line would be too long), never built at run time, so the
/// test can find them in the source. Log lines, the diagnostics file and anything else that isn't shown to the person
/// stay plain English: the bench and the export read them as they are.
enum AppText {
    /// The catalogue's table: `Localizable.xcstrings` compiles to `Localizable`.
    static let table = "Localizable"

    /// A string with no arguments, e.g. `AppText.string("Cameras")`.
    static func string(_ key: String) -> String {
        lookUp(key, english: key)
    }

    /// A string with arguments, each already in words (a name, a size, a counted phrase): `%@` for the next one, or
    /// `%1$@`, `%2$@` to name them, and `%%` for a percent sign. The key is the English format, e.g.
    /// `AppText.format("%@ free", size)`. The arguments are put in by `substitute(_:_:)` on every platform, so a
    /// translation can reorder them and nothing goes through C varargs.
    static func format(_ key: String, _ arguments: String...) -> String {
        substitute(lookUp(key, english: key), arguments)
    }

    /// A counted phrase with its plural variants: `one` is the English for exactly 1 and `other`, the key, for every
    /// other count, each with one `%lld` for the number, e.g. `AppText.counted(n, one: "%lld file", other: "%lld
    /// files")` reads "1 file" and "3 files". The catalogue's entry varies by plural, so a language with more forms
    /// gets them. The number is plain digits on every platform ("1234 files"), as it was before the catalogue and as
    /// the copy writes every other number (`"12 of 1234 files"`, never `"12 of 1,234 files"`).
    static func counted(_ count: Int, one: String, other: String) -> String {
        let english = count == 1 ? one : other
        #if canImport(Darwin)
        // `localizedStringWithFormat` picks the plural variant for the person's language, and also writes the number
        // in their locale ("1,234", "1.234"): that is taken back to plain digits.
        let text = String.localizedStringWithFormat(lookUp(other, english: english), count)
        let localDigits = String.localizedStringWithFormat("%lld", count)
        let plainDigits = String(count)
        return localDigits == plainDigits ? text : text.replacingOccurrences(of: localDigits, with: plainDigits)
        #else
        return english.replacingOccurrences(of: "%lld", with: String(count))
        #endif
    }

    /// The catalogue's text for `key`, or `english` when it has none (and always on Linux).
    private static func lookUp(_ key: String, english: String) -> String {
        #if canImport(Darwin)
        Bundle.module.localizedString(forKey: key, value: english, table: table)
        #else
        english
        #endif
    }

    #if canImport(Darwin)
    /// Whether the compiled catalogue has `key`, for `AppTextCatalogueTests` in CI: a miss would fall back silently.
    static func catalogueHas(_ key: String) -> Bool {
        let missing = "\u{1}missing\u{1}"
        return Bundle.module.localizedString(forKey: key, value: missing, table: table) != missing
    }
    #endif

    /// Puts `arguments` into `format`: `%@` takes the next argument, `%n$@` the nth (from 1), `%%` is a percent sign.
    /// Anything else after a `%` is left as it is, and a placeholder with no argument reads as nothing.
    static func substitute(_ format: String, _ arguments: [String]) -> String {
        var result = ""
        var next = 0
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            guard character == "%" else {
                result.append(character)
                index = format.index(after: index)
                continue
            }
            let afterPercent = format.index(after: index)
            guard afterPercent < format.endIndex else {
                result.append(character)
                break
            }
            if format[afterPercent] == "%" {
                result.append("%")
                index = format.index(after: afterPercent)
            } else if format[afterPercent] == "@" {
                if next < arguments.count { result.append(arguments[next]) }
                next += 1
                index = format.index(after: afterPercent)
            } else if let (position, end) = positional(in: format, from: afterPercent) {
                if position >= 1, position <= arguments.count { result.append(arguments[position - 1]) }
                index = end
            } else {
                result.append(character)
                index = afterPercent
            }
        }
        return result
    }

    /// A `n$@` placeholder's position and the index after it, starting just after its `%`.
    private static func positional(in format: String, from start: String.Index) -> (Int, String.Index)? {
        var index = start
        var digits = ""
        while index < format.endIndex, let digit = format[index].wholeNumberValue, format[index].isASCII {
            digits.append(String(digit))
            index = format.index(after: index)
        }
        guard !digits.isEmpty, index < format.endIndex, format[index] == "$" else { return nil }
        let at = format.index(after: index)
        guard at < format.endIndex, format[at] == "@", let position = Int(digits) else { return nil }
        return (position, format.index(after: at))
    }
}
