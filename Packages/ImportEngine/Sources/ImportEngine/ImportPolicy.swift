/// The engine's numbers (backlog section 3, *Decisions taken here*). Internal, so tests can read them; the app has no
/// reason to change them.
struct ImportPolicy: Sendable {
    /// At most 4 progress updates a second (the criterion; the proposal's 250 ms).
    var progressInterval: Duration = .milliseconds(250)
    /// No byte progress for this long, while running, is a stall. A healthy still takes about 1–3 s (ARW is 44–48 MB
    /// at 38–42 MB/s; the worst case is JPG over MTP at 25.6 MB/s), so 30 s is about ten times that and half of
    /// ImageCaptureCore's roughly 60 s command limit. Counted from the attempt's start when the link reports none,
    /// and frozen while the job is paused.
    var stallTimeout: Duration = .seconds(30)
    /// How long a stalled job waits before trying the file again: lets ImageCaptureCore settle (*Continue* found the
    /// remaining files about 1 s after the tap in the spike).
    var stallRetryDelay: Duration = .seconds(5)
    /// Consecutive stalls of one file that are retried by themselves; after that the job stays paused (stalled)
    /// until the person resumes it. Never "failed" (decision 4).
    var automaticStallRetries = 3
    /// Backoff for real errors that may pass (busy, no answer), a size that doesn't match the listing and a staged
    /// file that vanished: 3 retries, so 4 tries over about 7.5 s, then the file has failed. Listing uses the same.
    var retryDelays: [Duration] = [.milliseconds(500), .seconds(2), .seconds(5)]
    /// A row that can't be written would mean importing the file again later, so after this many tries the job stops.
    var catalogueWriteAttempts = 2
    /// The rate is measured over the last this-many clean files: about 4 RAW+JPEG pairs, or 6 s at 40 MB/s.
    var rateSampleFiles = 8

    static let standard = ImportPolicy()
}
