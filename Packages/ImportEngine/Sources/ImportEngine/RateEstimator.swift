/// Throughput over the last few clean files: their bytes over the length of the union of their intervals, so two
/// files in flight together aren't counted twice. A file that was in flight across a pause or after an abandoned
/// attempt is never recorded, because its time isn't throughput (the spike logged 35.4 MB at 1745 MB/s for one).
struct RateEstimator: Sendable {
    struct Sample: Sendable, Hashable {
        var start: Duration
        var end: Duration
        var bytes: UInt64
    }

    let capacity: Int
    private(set) var samples: [Sample] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    mutating func record(start: Duration, end: Duration, bytes: UInt64) {
        samples.append(Sample(start: start, end: max(start, end), bytes: bytes))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// Bytes per second; nil with no samples or no elapsed time.
    var bytesPerSecond: Double? {
        guard !samples.isEmpty else { return nil }
        var union = Duration.zero
        var current: (start: Duration, end: Duration)?
        for s in samples.sorted(by: { $0.start < $1.start }) {
            if let c = current, s.start <= c.end {
                current = (c.start, max(c.end, s.end))
            } else {
                if let c = current { union += c.end - c.start }
                current = (s.start, s.end)
            }
        }
        if let c = current { union += c.end - c.start }
        let seconds = union.seconds
        guard seconds > 0 else { return nil }
        let bytes = samples.reduce(UInt64(0)) { $0 + $1.bytes }
        return Double(bytes) / seconds
    }
}
