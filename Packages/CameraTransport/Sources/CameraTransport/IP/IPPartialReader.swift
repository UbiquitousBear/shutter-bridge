import PTPKit

/// The rules of one `IPLink.bytes` call on a link that resumes (backlog Iteration 3, section 3; wireless plan W8):
/// where a partial file continues from, which SDIO_GetPartialLargeObject (0x9211) chunk comes next, and when a
/// checkpoint is due. Pure, so it is tested on Linux; `IPLink` sends the chunks and writes the file.
///
/// The spike's resume, which this follows: chunks of 4 MiB from the saved offset, a short read moving the offset by
/// what arrived, and the resume point saved as the read goes and on error (2 Nov 23:10: a read cut at 54 % by Wi-Fi
/// off resumed at its offset and the SHA-256 matched; `unverified` beyond that one run).
struct IPPartialReader: Sendable, Equatable {
    /// What a call given a partial file does.
    enum Start: Sendable, Equatable {
        /// Continue the partial file from this offset with 0x9211 reads.
        case resume(at: UInt64)
        /// The partial file already holds the whole object: cut it back to the object's size and return it.
        case complete
        /// Copy the object again from 0 into the same file, for the reason given (for the log).
        case restart(String)
    }

    /// What one chunk's answer means.
    enum Step: Sendable, Equatable {
        /// The first `offset` bytes are on disk and a resume could start there: report a checkpoint, then read on.
        case checkpoint(UInt64)
        /// The object is whole.
        case complete
        /// The answer can't be used (for the log); the offset is unchanged.
        case failed(String)
    }

    /// What ObjectInfo's 32-bit size field holds for an object of 4 GiB or more (ISO 15740). Such an object's end
    /// isn't known in this session, which lists no object properties, so it is never resumed or checkpointed (video
    /// isn't imported in 1.0 anyway).
    static let unknownSize = UInt64(UInt32.max)

    /// Whether an object of `size` bytes can be resumed: its end is known and it has bytes.
    static func canResume(objectSize size: UInt64) -> Bool {
        size > 0 && size != unknownSize
    }

    /// Where a call given a partial file of `fileLength` bytes (nil: no file) starts, for a resume `offset` into an
    /// object of `objectSize` bytes. The caller has checked the item's name and size (`CameraLink.bytes`); the file's
    /// own length is trusted only to hold at least `offset` bytes.
    static func start(offset: UInt64, fileLength: UInt64?, objectSize: UInt64) -> Start {
        guard canResume(objectSize: objectSize) else { return .restart("the object's size isn't known") }
        guard offset > 0 else { return .restart("nothing to continue from") }
        guard let fileLength else { return .restart("the partial file is missing") }
        guard fileLength >= offset else {
            return .restart("the partial file is shorter than its offset (\(fileLength) < \(offset))")
        }
        guard offset <= objectSize else {
            return .restart("the offset is past the object's end (\(offset) > \(objectSize))")
        }
        return offset == objectSize ? .complete : .resume(at: offset)
    }

    /// During a whole-file GetObject, whether a checkpoint is due now that `current` bytes are on disk, the last one
    /// having been at `previous`: each time the copy crosses a multiple of `stride` (the chunk size, so a GetObject
    /// reports what a chunked read would), never at the object's end, where nothing is left to resume.
    static func streamCheckpointDue(previous: UInt64, current: UInt64, objectSize: UInt64, stride: UInt64) -> Bool {
        current < objectSize && PTPPartialRead.crossesCheckpoint(from: previous, to: current, interval: stride)
    }

    let objectSize: UInt64
    let chunkSize: UInt32
    /// The bytes of the object on disk, counted from its start: where the next chunk begins.
    private(set) var offset: UInt64

    /// A reader continuing at `offset` (at most `objectSize`). A chunk size of 0 counts as 1.
    init(offset: UInt64, objectSize: UInt64, chunkSize: UInt32 = PTPPartialRead.defaultChunkSize) {
        self.objectSize = objectSize
        self.chunkSize = max(1, chunkSize)
        self.offset = min(offset, objectSize)
    }

    /// The next chunk to ask for, or nil once the object is whole.
    var nextChunk: PTPPartialRead.Chunk? {
        PTPPartialRead.nextChunk(at: offset, objectSize: objectSize, chunkSize: chunkSize)
    }

    var isComplete: Bool { offset >= objectSize }

    /// `count` bytes of `chunk` arrived and are on disk. A short read moves the offset by what arrived (the spike's
    /// rule) and the next chunk asks for the rest; a read of nothing, or of more than was asked, is refused, so a
    /// camera that answers that way can't hold the copy in a loop or write past the range.
    mutating func received(_ count: UInt64, of chunk: PTPPartialRead.Chunk) -> Step {
        guard chunk.offset == offset else {
            return .failed("a chunk at \(chunk.offset) answered with the copy at \(offset)")
        }
        guard count > 0 else { return .failed("0x9211 sent no bytes at \(chunk.offset)") }
        guard count <= UInt64(chunk.length) else {
            return .failed("0x9211 sent \(count) bytes for a chunk of \(chunk.length) at \(chunk.offset)")
        }
        offset = chunk.offset + count
        return isComplete ? .complete : .checkpoint(offset)
    }

    /// The resume point after a read of `chunk` broke off with `written` bytes of the object on disk: what arrived
    /// of the chunk (bytes come in order, so they are the object's), never past the chunk or the object.
    func checkpoint(afterBreakIn chunk: PTPPartialRead.Chunk, written: UInt64) -> UInt64 {
        max(offset, min(written, chunk.end, objectSize))
    }
}
