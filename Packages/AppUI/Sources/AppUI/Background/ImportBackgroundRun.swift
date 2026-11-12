import Foundation
import ImportEngine

/// What keeps an import going while the app is away: on iPhone a `BGContinuedProcessingTask`
/// (`ContinuedImportRunner`), started when the person taps *Import* or *Continue* (backlog Iteration 3, section 9,
/// and section 13, "One continued-task wrapper for both links"). A protocol so `ImportModel`'s rules (begin, report
/// progress in bytes, finish, and pause on expiry) are tested on Linux with a fake.
///
/// Without one, a Wi-Fi session was lost within about 5 s in the background (5 Nov), and nothing moved in 123 s
/// locked (2 Nov). With one, whole-card copies ran 709–1,207 s, locked for some of it, without expiring.
public protocol ImportBackgroundRun: Sendable {
    /// Starts a run with the system's title and subtitle (the continued-task UI shows them with the progress).
    /// Must follow a person's action (a tap on *Import* or *Continue*): iOS refuses a continued task otherwise. Throws
    /// when iOS doesn't start one; the import goes on in the foreground regardless.
    func begin(title: String, subtitle: String) async throws -> any ImportBackgroundHandle
}

/// One run, from `ImportBackgroundRun.begin(title:subtitle:)` to `finish(success:)`.
public protocol ImportBackgroundHandle: Sendable {
    /// The progress the system shows, in bytes (backlog Iteration 3, section 9, *Progress in bytes*), and a new title
    /// or subtitle when not nil. Ignored once the run has finished.
    func update(completedBytes: Int64, totalBytes: Int64, title: String?, subtitle: String?)
    /// Yields once when iOS ends the run early: an expiry, or the person tapping Stop in the system's continued-task
    /// UI. iOS's handler doesn't say which (backlog section 9, *The Live Activity records Stop separately*: recorded
    /// separately only where iOS tells). Finishes when the run finishes. One reader.
    var expired: AsyncStream<Void> { get }
    /// Ends the run: `success` when the import completed. Called once; later calls do nothing.
    func finish(success: Bool)
}

/// Why a run didn't start.
public enum ImportBackgroundRunError: Error, Sendable, Hashable {
    /// No continued task here (Linux, a Mac, the Simulator before W16 wires the live runner).
    case unavailable
    /// iOS refused the request (`submitTaskRequest` threw: not from a person's action, background refresh off, too
    /// many pending), or didn't start it in time.
    case refused
}

/// No background run: `begin` throws `.unavailable`. The default, so an app or a test that wires none behaves as
/// before (USB imports pause when the app leaves the foreground; decision 1).
public struct NoImportBackgroundRun: ImportBackgroundRun {
    public init() {}

    public func begin(title: String, subtitle: String) async throws -> any ImportBackgroundHandle {
        throw ImportBackgroundRunError.unavailable
    }
}

/// The copy the system's continued-task UI shows for an import. No camera name: over Wi-Fi it could carry the
/// camera's network name, which the app never shows outside the join (AGENTS.md).
public enum ImportBackgroundWording {
    public static let title = AppText.string("Importing photos")
    /// The title for a *Stage* job (Shamil, 11 Nov).
    public static let stagingTitle = AppText.string("Staging photos")

    /// The title for a job: `stagingTitle` when it was started as *Stage*, `title` otherwise.
    public static func title(staging: Bool) -> String { staging ? stagingTitle : title }

    /// "12 of 360 files" once the job has counted its files; "Getting ready…" before.
    public static func subtitle(_ progress: ImportProgress) -> String {
        guard progress.filesTotal > 0 else { return AppText.string("Getting ready…") }
        return AppText.format("%@ of %@", String(progress.filesDone), ByteWording.files(progress.filesTotal))
    }
}
