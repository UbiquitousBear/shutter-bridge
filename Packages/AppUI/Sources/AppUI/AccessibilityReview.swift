import Foundation

// What the VoiceOver review of Iteration 2's screens added (I17; backlog section 9): the rules behind the fixes, in
// plain Swift so they are tested on Linux. The views that use them (`HistoryScreen`, `LoupeView`, `SettingsScreen`) are
// compiled by CI only, and VoiceOver itself is checked on the bench iPhone (iteration-2-bench.md).

// MARK: - History: what a double tap on a row does

extension HistoryRow {
    /// What a VoiceOver double tap on a row does. The row is one element with its buttons as actions, so without a
    /// default action a double tap lands wherever the row's middle is: on Resume's button, or on nothing.
    public enum SpokenDefault: Sendable, Hashable {
        /// Resume, or Re-run Failed Files.
        case act
        /// A stage job's Staging folder.
        case openFolder
    }

    /// The row's default action: its Resume or Re-run Failed Files when it has one and isn't busy with it, else its
    /// Staging folder when its files went there; nil when a double tap has nothing to do (the row is then no button).
    public func spokenDefault(isBusy: Bool) -> SpokenDefault? {
        if action != nil { return isBusy ? nil : .act }
        return opensStagingFolder ? .openFolder : nil
    }
}

extension HistoryWording {
    /// A row's VoiceOver value while its Resume or Re-run reads the card to queue the files (the spinner in place of
    /// the button).
    public static let busyValue = AppText.string("Reading the card…")
}

// MARK: - The loupe: the preview's state, which the photo element hides

extension CullWording {
    /// While the preview is decoded.
    public static let loadingPreview = AppText.string("Loading the preview")

    /// "Downloading from iCloud Drive, 40 percent", or `downloading` while how far isn't known.
    public static func downloadingSpoken(fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return downloading }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return AppText.format("Downloading from iCloud Drive, %@ percent", String(percent))
    }

    /// What VoiceOver adds to the photo's value when no preview is shown: the photo is one element, so the download's
    /// progress, the failure and its Try Again, or the missing preview would otherwise not be said at all. Nil once the
    /// preview shows.
    public static func previewStatusSpoken(hasPreview: Bool, hasNoPreview: Bool, previewFailed: Bool,
                                           download: DownloadProgress?) -> String? {
        if hasPreview { return nil }
        if hasNoPreview { return noPreview }
        if previewFailed { return previewFailedTitle }
        if let download { return downloadingSpoken(fraction: download.fraction) }
        return loadingPreview
    }
}

extension CullLoupe {
    /// The preview's state for VoiceOver, when no preview is shown (`CullWording.previewStatusSpoken`).
    public var previewStatusSpoken: String? {
        CullWording.previewStatusSpoken(hasPreview: preview != nil, hasNoPreview: hasNoPreview,
                                        previewFailed: previewFailed, download: download)
    }

    /// The photo's VoiceOver value with the preview's state after it: "3 of 120, No mark, Downloading from iCloud
    /// Drive, 40 percent".
    public var spokenValue: String {
        [accessibilityValue, previewStatusSpoken].compactMap(\.self).joined(separator: ", ")
    }
}

// MARK: - Export Diagnostics: the state changes, announced

extension SettingsModel {
    /// What VoiceOver announces when the export's state changes: that the file is being made (the row only dims), and
    /// a failure, urgently, as it appears under the row out of VoiceOver's focus. Nothing for the share sheet, which
    /// VoiceOver reads by itself.
    public var exportAnnouncement: StatusAnnouncement? {
        switch exportState {
        case .preparing: StatusAnnouncement(DiagnosticsWording.preparing)
        case let .failed(text): StatusAnnouncement(text, priority: .high)
        case .idle, .ready: nil
        }
    }
}
