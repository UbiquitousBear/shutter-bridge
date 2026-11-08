/// Where a job is, counted in bytes (decision 4): what the Import screen and, later, the Live Activity show. The
/// engine publishes it at most four times a second (backlog section 3).
public struct ImportProgress: Sendable, Hashable {
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    /// Measured throughput, nil until there is a measurement. It leaves out a file that was in flight across a
    /// suspension or a pause, whose rate isn't throughput (the spike logged 1745 MB/s for one such file).
    public var bytesPerSecond: Double?

    public init(filesDone: Int, filesTotal: Int, bytesDone: UInt64, bytesTotal: UInt64, bytesPerSecond: Double? = nil) {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
    }

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
