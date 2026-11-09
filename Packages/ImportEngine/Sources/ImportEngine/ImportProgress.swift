import CameraTransport
import PhotosBridge

/// Where a job is, counted in bytes (decision 4): what the Import screen and, later, the Live Activity show. The
/// engine publishes it at most four times a second (backlog section 3).
public struct ImportProgress: Sendable, Hashable {
    /// Files resolved one way or another: imported, skipped or failed.
    public var filesDone: Int
    /// Every file in the job, including files appended while it runs.
    public var filesTotal: Int
    /// The bytes of resolved files, plus the full size of files being committed, plus what each download in flight
    /// has written so far (never more than its size). Counting resolved files in full keeps the bar and the ETA
    /// consistent when a file is skipped or fails. Never goes backwards: a file whose download restarts (a stall, a
    /// removal, a retry) keeps the most it had shown until the new attempt passes it.
    public var bytesDone: UInt64
    /// The sum of the listed sizes of every file in the job.
    public var bytesTotal: UInt64
    /// Measured throughput, nil until there is a measurement. It leaves out a file that was in flight across a
    /// suspension or a pause, whose rate isn't throughput (the spike logged 1745 MB/s for one such file).
    public var bytesPerSecond: Double?
    /// The job's state when this was taken.
    public var state: ImportJobState
    /// Where the files are going and why, so the Import screen can name it from the first file (backlog section 5).
    public var destination: DestinationDecision?
    /// Files left out (part of `filesDone`).
    public var filesSkipped: Int
    /// Files that failed after their retries (part of `filesDone`).
    public var filesFailed: Int
    /// The carrier of an import that is running, or paused only for what it gets over without the person (a
    /// removal, a lost card or session, a stall it retries by itself); nil otherwise
    /// (`ImportEngine.importRunning(carrier:)`).
    public var runningCarrier: CameraCarrier?
    /// A file stalled more often than the automatic retries allow, so the stall pause waits for the person's
    /// Continue rather than lifting itself after 5 s (decision 4). False otherwise.
    public var stallWaitsForPerson: Bool

    public init(
        filesDone: Int, filesTotal: Int, bytesDone: UInt64, bytesTotal: UInt64, bytesPerSecond: Double? = nil,
        state: ImportJobState = .idle, destination: DestinationDecision? = nil, filesSkipped: Int = 0,
        filesFailed: Int = 0, runningCarrier: CameraCarrier? = nil, stallWaitsForPerson: Bool = false
    ) {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
        self.state = state
        self.destination = destination
        self.filesSkipped = filesSkipped
        self.filesFailed = filesFailed
        self.runningCarrier = runningCarrier
        self.stallWaitsForPerson = stallWaitsForPerson
    }

    /// Whether an import over `carrier` is running (`runningCarrier`).
    public func importRunning(carrier: CameraCarrier) -> Bool { runningCarrier == carrier }

    /// Whether a USB import is running, so the app keeps the screen on (decision 1); the screen-on rule stays
    /// USB-only, since a Wi-Fi import runs inside the continued task with the phone locked.
    public var isUSBImportRunning: Bool { importRunning(carrier: .usb) }

    public static let none = ImportProgress(filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0)

    public var bytesRemaining: UInt64 { bytesTotal > bytesDone ? bytesTotal - bytesDone : 0 }

    /// 0 to 1, by bytes; 0 for an empty job.
    public var fractionCompleted: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    /// Bytes left at the measured rate; nil without a positive rate.
    public var estimatedTimeRemaining: Duration? {
        guard let rate = bytesPerSecond, rate > 0, rate.isFinite else { return nil }
        return .milliseconds((Double(bytesRemaining) / rate * 1000).rounded(.up))
    }

    /// The rate in MB/s (10^6 bytes, as the spike's measurements are), for display.
    public var megabytesPerSecond: Double? { bytesPerSecond.map { $0 / 1_000_000 } }
}
