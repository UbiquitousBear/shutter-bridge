import CameraTransport

// The two timings the bench sheet asks the log for (docs/iteration-2-bench.md, checks 5 to 7; decision D1): how long
// the job took to carry on after the camera went away, and when the first byte came after that. Read from the engine's
// clock, so tests time them on the manual clock. Each is a trace event only: nothing here changes what the engine does.

extension ImportEngine {
    /// The camera or its card went away: remember when, once (a second loss before the card is listed again keeps the
    /// first, so the time covers the whole outage).
    func noteLost(_ job: Job) {
        guard job.lostAt == nil, job.finished == nil else { return }
        job.lostAt = clock.now
    }

    /// The card is listed again after a loss and the queue is released: say so, with the time since the loss, and start
    /// the clock for the first byte. Nothing for a job that was never interrupted (a first listing's retry).
    func noteReconnected(_ job: Job) {
        guard let lostAt = job.lostAt else { return }
        let now = clock.now
        job.lostAt = nil
        job.resumedAt = now
        trace(.reconnected(job.link.descriptor.carrier, sinceLost: max(.zero, now - lostAt), filesLeft: job.queue.count))
    }

    /// The first progress report of a download after `noteReconnected`.
    func noteFirstByte(of entry: FileEntry, in job: Job, reading: (bytes: UInt64, grewAt: Duration?)) {
        guard let resumedAt = job.resumedAt, reading.bytes > 0 else { return }
        job.resumedAt = nil
        let at = reading.grewAt ?? clock.now
        trace(.firstByteAfterReconnect(entry.item.name, bytes: reading.bytes, sinceResumed: max(.zero, at - resumedAt)))
    }
}
