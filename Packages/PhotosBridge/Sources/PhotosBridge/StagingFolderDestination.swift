import Foundation

/// The staging destination (Shamil, 11 Nov; *Stage* at Browse's Import button): the camera's originals, byte for
/// byte, in a folder per camera and capture day, ready to cull. Never asks for Photos access and never writes to
/// Photos.
///
/// - Layout: `root`/Staging/`camera`/`YYYY-MM-DD`/, the day being the capture date as the camera's clock read it,
///   in the job's time zone (the zone the link turned the camera's zone-less time into a `Date` in, as for
///   `CaptureDate`). Both files of a pair go to the RAW's day. A file with no capture date goes to "Undated" (the
///   engine skips such files anyway).
/// - `root` is the Documents folder of the app's iCloud container (iCloud Drive › Shutter Bridge › Staging), or the
///   app's own Documents folder (On My iPhone › Shutter Bridge › Staging) when iCloud Drive isn't available;
///   `place` says which, for the result.
/// - Placement is `FolderPlacer`'s: each staged file is moved, never copied, through `mover` (`UbiquitousFileMover`
///   into iCloud Drive, `PlainFileMover` on this iPhone); a name already in the folder is never overwritten (an
///   iCloud placeholder counts as taken); a pair shares one number; the modification date is the capture date; a
///   failed pair leaves both files staged.
/// - It returns each file's path relative to `root`, because the container's absolute path changes between installs
///   and updates.
///
/// No album and no pairing into one asset apply here. Pure Foundation with `PlainFileMover`, tested on Linux with
/// temporary directories; the iCloud container is in the hardware plan.
public actor StagingFolderDestination: ImportDestination {
    public nonisolated let kind: DestinationKind = .staging

    /// The staging root: the iCloud container's Documents folder, or the app's Documents folder.
    public nonisolated let root: URL
    /// Which of the two `root` is.
    public nonisolated let place: StagingPlace
    /// The camera's folder name, already made safe (`FilesFolderNaming.folderName(forCamera:)`).
    public nonisolated let cameraFolderName: String
    /// The zone capture days are read in.
    public nonisolated let timeZone: TimeZone
    private let mover: any StagedFileMover

    /// The staging folder's name under the root.
    public static let folderName = "Staging"
    /// The day folder of a file with no capture date.
    public static let undatedFolderName = "Undated"

    /// - Parameters:
    ///   - root: the staging root (`StagingAvailability.iCloudDocuments`, or the app's Documents folder); tests pass
    ///     a temporary directory.
    ///   - place: which root it is, for the result and the Import screen.
    ///   - cameraName: the camera's name, for example its model name; made into a safe folder name.
    ///   - timeZone: the job's zone, for the capture day.
    ///   - mover: how files are moved into the folder.
    public init(root: URL, place: StagingPlace, cameraName: String, timeZone: TimeZone,
                mover: any StagedFileMover = PlainFileMover()) {
        self.root = root
        self.place = place
        cameraFolderName = FilesFolderNaming.folderName(forCamera: cameraName)
        self.timeZone = timeZone
        self.mover = mover
    }

    /// The camera's folder: `root`/Staging/`cameraFolderName`.
    public nonisolated var cameraFolderURL: URL {
        root.appendingPathComponent(Self.folderName, isDirectory: true)
            .appendingPathComponent(cameraFolderName, isDirectory: true)
    }

    /// The camera's folder relative to the root, "Staging/`cameraFolderName`", for the Import screen.
    public nonisolated var cameraFolderPath: String { Self.folderName + "/" + cameraFolderName }

    public func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        let day = dayFolder(of: unit)
        let folder = cameraFolderURL.appendingPathComponent(day, isDirectory: true)
        let placed = try FolderPlacer(folder: folder, mover: mover).place(unit.files)
        let prefix = dayFolderPath(day) + "/"
        return .staged(place: place, placed.map { FileLocation(relativePath: prefix + $0.lastPathComponent) })
    }

    /// The day folder `commit(_:)` places `unit` in, relative to the root ("Staging/`camera`/`YYYY-MM-DD`").
    public nonisolated func commitTarget(for unit: CommitUnit) -> CommitTarget {
        .stagingFolder(place: place, folderPath: dayFolderPath(dayFolder(of: unit)))
    }

    /// The unit's day folder's name: the RAW's (the first file's) capture day.
    private nonisolated func dayFolder(of unit: CommitUnit) -> String {
        Self.dayFolderName(for: unit.files.first?.captureDate, in: timeZone)
    }

    /// A day folder relative to the root.
    private nonisolated func dayFolderPath(_ day: String) -> String { cameraFolderPath + "/" + day }

    /// "YYYY-MM-DD" for `date` read as wall-clock time in `timeZone`; "Undated" when there is no date or its year is
    /// outside 0001–9999.
    public static func dayFolderName(for date: Date?, in timeZone: TimeZone) -> String {
        guard let date else { return undatedFolderName }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard c.era == 1, let y = c.year, let m = c.month, let d = c.day, (1 ... 9999).contains(y) else {
            return undatedFolderName
        }
        func pad(_ v: Int, _ width: Int) -> String {
            let digits = String(v)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2)
    }
}
