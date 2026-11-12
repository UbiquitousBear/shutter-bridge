import Foundation
import PhotosBridge

/// *Import keepers* and the removal from Staging after it (backlog sections 7.5 and 7.6; D2), in British English: titles
/// in title case, the rest in sentence case, as the other screens' wording (HIG Writing). Keepers, rejects and unmarked
/// photos are counted in units, as the cull screen counts them (a RAW+JPEG pair is one); files are files.
public enum KeepersWording {
    // MARK: Starting

    public static let importKeepers = "Import Keepers"
    public static let importKeepersHint = "Imports the photos you kept to Photos, then offers to remove the staged copies."
    public static let importDayKeepers = "Import Keepers of This Day"
    public static func importCameraKeepers(_ cameraName: String) -> String { "Import Keepers of \(cameraName)" }

    // MARK: While it runs

    /// The Import screen's line for the job shown: "Importing keepers from Staging" for one camera's keepers, "Keepers,
    /// 2 of 3 cameras" when they come from several (one job per camera).
    public static func sequence(_ sequence: KeepersSequence) -> String {
        sequence.count <= 1 ? "Importing keepers from Staging"
            : "Keepers, \(sequence.index) of \(sequence.count) cameras"
    }

    /// A keepers job's file it didn't get to: still in Staging (a card's file would be "still on the card").
    public static let notImported = "Not imported: still in Staging"

    public static let preparing = "Reading the keepers…"

    /// Evicted iCloud files are downloaded before the job starts, so a long download can't stall the import.
    public static func downloading(done: Int, of total: Int) -> String {
        "Downloading \(photos(total)) from iCloud Drive before the import (\(done) of \(total))…"
    }

    public static let importing = "Importing keepers to Photos…"
    public static let removing = "Removing staged copies…"

    // MARK: The one confirmation (D2)

    /// "Remove 120 Staged Files?"
    public static func confirmTitle(_ plan: StagingRemovalPlan) -> String {
        plan.copies.count == 1 ? "Remove 1 Staged File?" : "Remove \(plan.copies.count) Staged Files?"
    }

    /// "34 keepers are in Photos; 86 rejects will be deleted from Staging. Unmarked files stay.", with what is held
    /// back after it.
    public static func confirmMessage(_ plan: StagingRemovalPlan) -> String {
        var first: [String] = []
        if plan.keepersInPhotos > 0 {
            first.append(plan.keepersInPhotos == 1 ? "1 keeper is in Photos" : "\(plan.keepersInPhotos) keepers are in Photos")
        }
        if plan.rejects > 0 {
            first.append((plan.rejects == 1 ? "1 reject" : "\(plan.rejects) rejects") + " will be deleted from Staging")
        }
        var lines = [first.isEmpty ? "" : capitalisedFirst(first.joined(separator: "; ")) + "."]
        if plan.keepersHeld > 0 {
            var held = plan.keepersHeld == 1 ? "1 keeper isn't in Photos, so it stays in Staging with its mark"
                : "\(plan.keepersHeld) keepers aren't in Photos, so they stay in Staging with their marks"
            if plan.rejectsHeld > 0 {
                held += plan.rejectsHeld == 1 ? ", and so does 1 reject of the same day"
                    : ", and so do \(plan.rejectsHeld) rejects of the same days"
            }
            lines.append(held + ".")
        }
        lines.append("Unmarked files stay.")
        return lines.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static let remove = "Remove"
    public static let keepInStaging = "Keep in Staging"

    // MARK: When it's done

    /// What *Import keepers* did, for the cull screen's strip.
    public static func finished(_ summary: KeepersSummary) -> String {
        var parts: [String] = []
        switch summary.problem {
        case .couldNotRead?: return "Couldn't read the marks, so nothing was imported or removed."
        case .nothingToDo?: return "No keepers or rejects to import or remove."
        case nil: break
        }
        if let run = summary.run {
            switch run.end {
            case .completed:
                parts.append("\(files(run.filesImported)) imported to Photos")
            case let .photosAccessNeeded(access):
                parts.append(ImportWording.photosAccessNeeded(access) + " Nothing was removed from Staging")
            case .ended:
                parts.append("The import stopped, so nothing was removed from Staging")
            case .notStarted:
                parts.append("Another import is running. Import the keepers when it's done")
            }
            if run.alreadyImported > 0 { parts.append("\(files(run.alreadyImported)) already in Photos") }
            if run.rejectedSince > 0 { parts.append("\(files(run.rejectedSince)) rejected since, not imported") }
            if run.filesSkipped > 0 { parts.append("\(run.filesSkipped) skipped") }
            if run.filesFailed > 0 { parts.append("\(run.filesFailed) failed and stay in Staging") }
        }
        if let removal = summary.removal {
            parts.append("\(files(removal.removed)) removed from Staging")
            if removal.failed > 0 {
                parts.append("\(files(removal.failed)) couldn't be removed and stay staged; try again from Staging")
            }
        } else if summary.plan != nil {
            parts.append("Nothing was removed from Staging")
        }
        return parts.joined(separator: "; ") + "."
    }

    // MARK: Parts

    static func photos(_ n: Int) -> String { n == 1 ? "1 photo" : "\(n) photos" }
    static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    private static func capitalisedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
