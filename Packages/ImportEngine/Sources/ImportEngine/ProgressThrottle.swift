/// Keeps progress to at most one update per interval (4 a second): the first value goes out at once, a changed value
/// goes out when the interval since the last one has passed, and anything in between waits as the one pending value
/// (the newest replaces the older), which `due(at:)` releases once the interval is up.
struct ProgressThrottle: Sendable {
    let interval: Duration
    private(set) var lastPublished: ImportProgress?
    private(set) var lastPublishedAt: Duration?
    private(set) var pending: ImportProgress?

    init(interval: Duration) { self.interval = interval }

    var hasPending: Bool { pending != nil }

    /// A new value; returns it if it should be published now.
    mutating func offer(_ p: ImportProgress, at now: Duration) -> ImportProgress? {
        guard let last = lastPublished, let at = lastPublishedAt else { return mark(p, now) }
        if p == last {
            pending = nil
            return nil
        }
        if now - at >= interval { return mark(p, now) }
        pending = p
        return nil
    }

    /// The pending value, once the interval since the last publish has passed.
    mutating func due(at now: Duration) -> ImportProgress? {
        guard let p = pending, let at = lastPublishedAt, now - at >= interval else { return nil }
        return mark(p, now)
    }

    private mutating func mark(_ p: ImportProgress, _ now: Duration) -> ImportProgress {
        lastPublished = p
        lastPublishedAt = now
        pending = nil
        return p
    }
}
