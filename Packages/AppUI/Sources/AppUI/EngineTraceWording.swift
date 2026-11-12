import CameraTransport
import Foundation
import ImportEngine
import PhotosBridge

// The engine's own decisions in the log (backlog section 6; I8): each `EngineTrace` event the engine emits becomes at most one
// line in the unified log and the rolling file through `BenchLog`. Plain Swift, tested on Linux for the exact wording, the
// level and the absence of private data. Lines start "engine:". Times are seconds to a tenth (`TransportTraceWording`'s
// form), sizes in bytes, counts as numbers. docs/iteration-2-bench.md ("What the log holds") quotes these formats.
//
// What a line may hold: the camera's file name (as the camera lists it, with any control character replaced, at most 64
// characters), sizes, counts, times, and the kinds of pause, skip and failure. Never a serial, an identifier, a network name or
// address, nor the text of an error: a destination's `rejected(detail:)` is said as "rejected" only.
//
// Levels: a real failure is an error (a file that failed after its retries, a destination error, a job the engine
// stopped, the catalogue being unavailable, a commit the catalogue couldn't mark as pending); everything else is a
// notice, whatever the event: pauses, stalls that recover, retries, skips, reconnects, a job record History will have
// to wait for. The events that fire constantly or that the import's own lines already carry have no line: ticks,
// progress publications, the download loop idling, a late file discarded, a file started the first time, a file
// imported or staged (the import model logs those with their identity), a pair's half waiting for its partner, and the
// engine's `idle`.

extension EngineTraceSink {
    /// Writes each event that has a line to `log`, at the event's level.
    public static func bench(_ log: any BenchLog) -> EngineTraceSink {
        EngineTraceSink { event in
            guard let line = EngineTraceWording.line(for: event) else { return }
            log.note(line, level: EngineTraceWording.level(for: event))
        }
    }
}

public enum EngineTraceWording {
    /// How serious the event is: `.error` for the failures that count against the definition of done, `.notice` for the rest.
    public static func level(for event: EngineTrace) -> BenchLogLevel {
        switch event {
        case .failed, .commitMarkerNotWritten:
            return .error
        case let .finished(outcome):
            switch outcome {
            case .stopped, .catalogueUnavailable: return .error
            // The person's Photos setting, not a failure of the import: the keepers wait in Staging.
            case .completed, .cancelled, .photosAccessNeeded: return .notice
            }
        case .listed, .started, .retrying, .stalled, .sizeMismatch, .imported, .staged, .alreadyStaged, .skipped,
             .sameFileListedTwice, .waitingForPartner, .committedWithoutPartner, .destinationChanged, .routeRefused,
             .linkEvent, .paused, .resumed, .idle, .tick,
             .published, .discardedLateFile, .checkpointSaved, .waitingForCheckpointWrites, .checkpointWritesUnsettled,
             .identityChanged, .reconnected, .firstByteAfterReconnect, .jobRecordNotWritten, .lateSessionLossIgnored,
             .partialReset, .rejectedLeftOut,
             .pendingCommitResolved:
            return .notice
        }
    }

    /// The event's line; nil for an event that has none (see the list above).
    public static func line(for event: EngineTrace) -> String? {
        switch event {
        case let .listed(onCard, queued):
            return "engine: listed \(onCard) on the card, \(queued) to copy"
        case let .started(name, attempt):
            // The first attempt is the common case, and the import's line follows it.
            return attempt > 1 ? "engine: copying \(file(name)) again, attempt \(attempt)" : nil
        case let .retrying(name, retry, _):
            if name == EngineTrace.listingName { return "engine: listing the card failed, trying again (retry \(retry))" }
            return "engine: \(file(name)) failed, trying again (retry \(retry))"
        case let .stalled(name, count):
            return "engine: stall \(count) on \(file(name)), retrying"
        case let .sizeMismatch(name, expected, actual):
            return "engine: \(file(name)) came to \(actual) B but the camera lists \(expected) B"
        case .imported, .staged:
            return nil
        case let .alreadyStaged(name):
            return "engine: skipped \(file(name)): already staged"
        case let .rejectedLeftOut(name):
            return "engine: skipped \(file(name)): rejected"
        case let .skipped(name, reason):
            return "engine: skipped \(file(name)): \(skipWord(reason))"
        case let .sameFileListedTwice(name):
            return "engine: left out a second copy of \(file(name)) listed in another folder"
        case let .failed(name, reason):
            return "engine: failed \(file(name)): \(failureWord(reason))"
        case .waitingForPartner:
            // Every pair waits for its second half; the commit's own lines follow.
            return nil
        case let .committedWithoutPartner(name):
            return "engine: committed \(file(name)) without the other half of its pair"
        case let .destinationChanged(decision):
            return "engine: the destination is now \(decisionWord(decision))"
        case let .routeRefused(decision):
            return "engine: kept the job's destination; \(decisionWord(decision)) isn't allowed mid-job"
        case let .linkEvent(event):
            return "engine: camera link: \(linkEventWord(event))"
        case let .paused(reason):
            return "engine: paused (\(pauseWord(reason)))"
        case .resumed:
            return "engine: continued"
        case .idle, .tick, .published, .discardedLateFile:
            return nil
        case let .checkpointSaved(name, offset):
            return "engine: checkpoint \(file(name)) at \(offset) B"
        case let .waitingForCheckpointWrites(name):
            return "engine: \(file(name)) is waiting for a checkpoint write before its row"
        case let .checkpointWritesUnsettled(name):
            return "engine: \(file(name))'s row was written without the checkpoint write it waited for"
        case let .identityChanged(name):
            return "engine: \(file(name)) changed on the camera since its partial copy began; copying it again"
        case let .commitMarkerNotWritten(name):
            return "engine: catalogue unavailable: \(file(name)) wasn't committed and goes back in the queue"
        case .jobRecordNotWritten:
            return "engine: the job's History record couldn't be written; trying again at its next change"
        case let .finished(outcome):
            switch outcome {
            case .completed: return "engine: job finished: completed"
            case .cancelled: return "engine: job finished: cancelled"
            case let .stopped(kind): return "engine: job stopped: \(kindWord(kind))"
            case .catalogueUnavailable: return "engine: catalogue unavailable: the job stopped"
            case let .photosAccessNeeded(authorisation):
                return "engine: job stopped: Photos refused the save (access \(authorisation.rawValue)); "
                    + "nothing staged"
            }
        case let .reconnected(carrier, sinceLost, filesLeft):
            let since = sinceLost.map { ", \(TransportTraceWording.seconds($0)) after the camera went away" } ?? ""
            let files = filesLeft == 1 ? "1 file left" : "\(filesLeft) files left"
            return "engine: job resumed after a reconnect (\(carrier.rawValue))\(since), \(files)"
        case let .firstByteAfterReconnect(name, bytes, sinceResumed):
            return "engine: first byte after the reconnect: \(file(name)) at \(bytes) B, "
                + "\(TransportTraceWording.seconds(sinceResumed)) after the job resumed"
        case let .lateSessionLossIgnored(generation):
            return "engine: ignored a late loss of session \(generation), which the reconnect replaced"
        case let .partialReset(name):
            return "engine: the partial copy of \(file(name)) is gone; it will be copied from its start"
        case let .pendingCommitResolved(name, resolution):
            return "engine: interrupted commit of \(file(name)): \(resolutionWord(resolution))"
        }
    }

    // MARK: Parts

    /// A file name for a line: control characters replaced, and cut at 64 characters, so a name the camera sent can't write
    /// a second line or fill the log.
    static func file(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control ? "?" : Character(scalar)
        })
        return cleaned.count > 64 ? String(cleaned.prefix(64)) + "…" : cleaned
    }

    /// How a pending commit left behind was resolved (backlog section 3.1, I15).
    static func resolutionWord(_ resolution: PendingCommitResolution) -> String {
        switch resolution {
        case .replayed: "its row was written from memory"
        case .foundInPhotos: "found in Photos, marked imported"
        case .foundInStaging: "found in Staging, marked staged"
        case .spareStagedCopy: "found in Staging, but the file has a staged copy elsewhere; the spare is left in place"
        case .notFound: "not found, so it reads as not imported"
        case .notStaged: "not found in Staging, so it reads as not staged"
        case .possibleDuplicate: "not found with Limited Access, so it may be imported twice"
        case .waiting: "can't be checked yet; kept for the next pass"
        case .forgotten: "its camera's imports were forgotten, so it reads as not imported"
        }
    }

    static func skipWord(_ reason: ImportSkipReason) -> String {
        switch reason {
        case let .link(kind): kindWord(kind)
        case .notAStill: "not a still"
        case .noCaptureDate: "no capture date"
        case .alreadyStaged: "already staged"
        }
    }

    static func failureWord(_ reason: ImportFailureReason) -> String {
        switch reason {
        case let .link(kind): kindWord(kind)
        case let .sizeMismatch(expected, actual): "it came to \(actual) B but the camera lists \(expected) B"
        case let .destination(failure): destinationWord(failure)
        }
    }

    /// What a destination's failure says, without its detail text.
    static func destinationWord(_ failure: ImportDestinationFailure) -> String {
        switch failure {
        case .photosAccessDenied: "Photos access is denied"
        case .notEnoughSpace: "this iPhone has no room"
        case .stagedFileMissing: "the downloaded file was gone"
        case .stagingUnavailable: "the staging folder was unavailable"
        case .rejected: "the destination rejected it"
        }
    }

    static func kindWord(_ kind: CameraLinkFailure.Kind) -> String {
        switch kind {
        case .busy: "the camera was busy"
        case .noAnswer: "the camera gave no answer"
        case .disconnected: "the camera disconnected"
        case .itemNotFound: "no longer on the card"
        case .unreadableItem: "the camera couldn't read it"
        case .unsupportedFormat: "a format that isn't imported"
        case .phoneStorageFull: "this iPhone is full"
        case .notAuthorised: "not allowed to use the camera"
        case .modeListsNoFiles: "the camera's mode lists no files"
        case .identityChanged: "a different camera answered"
        case .refused: "the camera refused the connection"
        case .cardUnavailable: "the card isn't available"
        }
    }

    static func pauseWord(_ reason: PauseReason) -> String {
        switch reason {
        case .appInBackground: "the app left the foreground"
        case .cameraRemoved: "the camera was removed"
        case .stalled: "a download stalled"
        case .byPerson: "paused by the person"
        case .taskExpired: "the continued task ended"
        case .cardUnavailable: "the card isn't available"
        case .cameraUnreachable: "the camera is unreachable"
        case .needsJoin: "the phone needs to join the camera's network"
        }
    }

    static func linkEventWord(_ event: CameraLinkEvent) -> String {
        switch event {
        case .removed: "removed"
        case .willSuspend: "will suspend"
        case .didSuspend: "suspended"
        case .cancelledSuspending: "suspension called off"
        case .resumedOperations: "operations resumed"
        case .waitingForLocalNetwork: "waiting for the Local Network prompt"
        case .storeRemoved: "card removed from the session"
        case .storeAdded: "card added back"
        case .sessionLost: "session lost"
        }
    }

    static func decisionWord(_ decision: DestinationDecision) -> String {
        switch decision {
        case .photos:
            return "Photos"
        case let .staging(reason, place):
            let location = switch place {
            case .iCloudDrive: "staging in iCloud Drive"
            case .onThisIPhone: "staging on this iPhone"
            }
            switch reason {
            case .chosen: return location
            case .photosDenied: return location + " (Photos access is off)"
            case .photosRestricted: return location + " (Photos is restricted)"
            }
        case .askForPhotosAccess:
            return "asking for Photos access"
        }
    }
}
