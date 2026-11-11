import Foundation
import ImportEngine
import PhotosBridge

// How the app's status messages are shown and spoken (HIG Accessibility > VoiceOver: tell people about changes in
// status; HIG Feedback: feedback reaches everyone; HIG Accessibility: give people enough time to read). The rules are
// plain Swift, tested on Linux; the screens only draw a `StatusNotice` and post a `StatusAnnouncement`.

/// What VoiceOver says when a status changes, and how urgently. The screens post it as an
/// `AccessibilityNotification.Announcement`, with high priority for pauses and failures so it isn't cut off.
public struct StatusAnnouncement: Sendable, Hashable {
    public enum Priority: Sendable, Hashable {
        case normal
        /// Pauses and failures: spoken even if VoiceOver is busy.
        case high
    }

    public var text: String
    public var priority: Priority

    public init(_ text: String, priority: Priority = .normal) {
        self.text = text
        self.priority = priority
    }
}

/// A message strip at the top of a screen: its text, its symbol, whether it goes by itself, and what VoiceOver says.
/// Problems (a refused import, a failed copy) stay until the person closes them; confirmations go after
/// `autoDismissDelay`, except while VoiceOver is running, when nothing goes by itself.
public struct StatusNotice: Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        case info
        case success
        /// A refusal or a failure: drawn with `exclamationmark.triangle`, kept until closed, announced urgently.
        case problem
    }

    /// Tells apart two notices with the same text (two Import taps in a row), so each is announced and timed.
    public var id: Int
    public var text: String
    public var tone: Tone
    /// The symbol before the text; a problem always shows `exclamationmark.triangle`.
    public var systemImage: String
    /// True for confirmations, which go after `autoDismissDelay`; false keeps the notice until it is closed.
    public var dismissesItself: Bool
    /// How urgently VoiceOver says it: high for problems, and for a warning that appears together with a screen
    /// change VoiceOver would otherwise read over it (a disconnect that pops Browse, a share sheet opening).
    public var announcementPriority: StatusAnnouncement.Priority

    /// - Parameter announcementPriority: Nil gives problems high priority and everything else normal.
    public init(id: Int = 0, text: String, tone: Tone, systemImage: String, dismissesItself: Bool,
                announcementPriority: StatusAnnouncement.Priority? = nil) {
        self.id = id
        self.text = text
        self.tone = tone
        self.systemImage = tone == .problem ? "exclamationmark.triangle" : systemImage
        self.dismissesItself = tone == .problem ? false : dismissesItself
        self.announcementPriority = tone == .problem ? .high : announcementPriority ?? .normal
    }

    /// How long a confirmation stays.
    public static let autoDismissDelay: Duration = .seconds(5)

    /// How long to wait before closing this notice by itself, or nil to keep it until the person closes it: problems
    /// always stay, and nothing goes by itself while VoiceOver is running (the person may not have reached it yet).
    public func dismissDelay(voiceOverRunning: Bool) -> Duration? {
        dismissesItself && !voiceOverRunning ? Self.autoDismissDelay : nil
    }

    /// What VoiceOver says when the notice appears.
    public var announcement: StatusAnnouncement {
        StatusAnnouncement(text, priority: announcementPriority)
    }

    /// After Import is tapped in Browse: a job started, files were added or there was nothing new (confirmations,
    /// which go by themselves), or a refusal or the engine's failure (kept until closed).
    ///
    /// - Parameter choice: What was asked for, *Import to Photos* or *Stage*, so the text says which.
    public static func importRequest(_ outcome: ImportRequestOutcome, id: Int = 0,
                                     choice: DestinationKind = .photos) -> StatusNotice {
        let text = BrowseWording.importRequested(outcome, choice: choice) ?? ""
        switch outcome {
        case .started, .appended, .nothingNew:
            return StatusNotice(id: id, text: text, tone: .info,
                                systemImage: choice == .staging ? "tray.and.arrow.down" : "square.and.arrow.down",
                                dismissesItself: true)
        case .busyWithAnotherCamera, .busyWithAnotherMode, .stillStarting, .failed:
            return StatusNotice(id: id, text: text, tone: .problem, systemImage: "exclamationmark.triangle",
                                dismissesItself: false)
        }
    }

    /// *Copy as JPEG* or *Share as JPEG…*'s confirmation (goes by itself) or error (kept until closed); nil while
    /// idle or working. *Sharing the camera's preview* is said urgently: the share sheet opens at the same moment
    /// and VoiceOver would read it instead.
    ///
    /// - Parameter id: The outcome's number (`BrowseModel` counts them), so the same text twice is announced twice.
    public static func jpegAction(_ state: JPEGActionState, id: Int = 0) -> StatusNotice? {
        switch state {
        case .idle, .working:
            nil
        case let .finished(message):
            StatusNotice(id: id, text: message, tone: .success, systemImage: "checkmark.circle", dismissesItself: true,
                         announcementPriority: message == JPEGWording.sharingPreview ? .high : .normal)
        case let .failed(message):
            StatusNotice(id: id, text: message, tone: .problem, systemImage: "exclamationmark.triangle",
                         dismissesItself: false)
        }
    }

    /// The Cameras screen's message (a camera went away while it was browsed): kept until the camera is back or the
    /// person closes it, as before. Said urgently: Browse closes at the same moment, and VoiceOver would read the
    /// Cameras screen instead.
    ///
    /// - Parameter id: The notice's number (`CamerasModel` counts them), so the same text twice is announced twice.
    public static func cameras(_ text: String, id: Int = 0) -> StatusNotice {
        StatusNotice(id: id, text: text, tone: .info, systemImage: "info.circle", dismissesItself: false,
                     announcementPriority: .high)
    }
}

extension ImportWording {
    /// The job's state as the Import screen's announcements see it: the state, and whether a stall is one the engine
    /// retries by itself (`ImportProgress.stallWaitsForPerson` false), which needs nothing from the person.
    public struct AnnouncedState: Sendable, Hashable {
        public var state: ImportJobState
        /// True while paused for a stall the engine lifts by itself after `ImportPolicy.stallRetryDelay`.
        public var isAutomaticRetry: Bool

        public init(state: ImportJobState, isAutomaticRetry: Bool = false) {
            self.state = state
            self.isAutomaticRetry = state == .paused(.stalled) && isAutomaticRetry
        }

        public init(_ progress: ImportProgress) {
            self.init(state: progress.state, isAutomaticRetry: !progress.stallWaitsForPerson)
        }
    }

    /// What VoiceOver says when the job's state changes kind on the Import screen, or nil to say nothing: not for
    /// byte or file progress (the state doesn't change then), not for a job starting (Browse's notice said so), and
    /// not twice for the same state. A pause or a stop is urgent, except a stall the engine retries by itself (said
    /// plainly, and its carrying on not said at all, so a flaky cable doesn't fill VoiceOver); a finish says the
    /// counts.
    ///
    /// - Parameters:
    ///   - old: The state before; equal to `new` says nothing.
    ///   - statusLine: The screen's status line for `new` (`ImportModel.statusLine`).
    ///   - counts: The counts line (`ImportModel.countsLine`), added once the job has finished.
    public static func stateAnnouncement(from old: AnnouncedState, to new: AnnouncedState, statusLine: String?,
                                         counts: String?) -> StatusAnnouncement? {
        guard old != new, let statusLine, !statusLine.isEmpty else { return nil }
        switch new.state {
        case .idle:
            return nil
        case .running:
            // Carrying on after a pause; a job that has just started was announced by Browse's notice, and the end
            // of an automatic retry needs no word.
            guard case .paused = old.state, !old.isAutomaticRetry else { return nil }
            return StatusAnnouncement(statusLine)
        case .paused:
            return StatusAnnouncement(statusLine, priority: new.isAutomaticRetry ? .normal : .high)
        case let .finished(outcome):
            let text = [statusLine, counts].compactMap { $0 }.joined(separator: " ")
            switch outcome {
            case .completed, .cancelled:
                return StatusAnnouncement(text)
            case .stopped, .catalogueUnavailable:
                return StatusAnnouncement(text, priority: .high)
            }
        }
    }

    /// `stateAnnouncement(from:to:statusLine:counts:)` for states with no automatic retry.
    public static func stateAnnouncement(from old: ImportJobState, to new: ImportJobState, statusLine: String?,
                                         counts: String?) -> StatusAnnouncement? {
        stateAnnouncement(from: AnnouncedState(state: old), to: AnnouncedState(state: new), statusLine: statusLine,
                          counts: counts)
    }
}
