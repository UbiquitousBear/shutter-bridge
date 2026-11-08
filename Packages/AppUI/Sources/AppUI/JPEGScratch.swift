import Foundation

/// The temporary folders *Copy as JPEG* and *Share as JPEG…* work in (backlog section 6, *Where the file goes*): one
/// folder per action under the app's caches, removed when the action ends, and every leftover (a crash, a kill)
/// removed at the next launch. Nothing here is a catalogue row or an import.
///
/// Layout: `<root>/<UUID>/camera/` receives the link's download, and `<root>/<UUID>/jpeg/<stem>.jpg` is the JPEG
/// that is copied or shared, so the share sheet offers a file named after the camera's file.
public struct JPEGScratch: Sendable, Hashable {
    /// The folder under the caches that holds every action's folder.
    public static let folderName = "CopyAsJPEG"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `Library/Caches/CopyAsJPEG` in the app's container (the system may also purge Caches when space runs low,
    /// which is fine for files this short-lived).
    public static func inCaches() -> JPEGScratch {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return JPEGScratch(root: caches.appendingPathComponent(folderName, isDirectory: true))
    }

    /// One action's folder.
    public struct ActionFolder: Sendable, Hashable {
        public let url: URL

        /// Where the link writes the camera's file.
        public var download: URL { url.appendingPathComponent("camera", isDirectory: true) }
        /// Where the JPEG goes.
        public var output: URL { url.appendingPathComponent("jpeg", isDirectory: true) }

        /// The JPEG's path for a pressed file: "DSC00001.ARW" → `jpeg/DSC00001.jpg`.
        public func outputFile(forPressedName name: String) -> URL {
            output.appendingPathComponent(JPEGScratch.jpegName(forPressedName: name), isDirectory: false)
        }
    }

    /// Makes a fresh folder for one action, with its `camera` and `jpeg` folders inside.
    public func makeActionFolder(id: UUID = UUID()) throws -> ActionFolder {
        let folder = ActionFolder(url: root.appendingPathComponent(id.uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: folder.download, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.output, withIntermediateDirectories: true)
        return folder
    }

    /// Removes one action's folder and everything in it. Does nothing for a folder that isn't directly under `root`,
    /// so a wrong URL can never delete anything else.
    public func remove(_ folder: ActionFolder) {
        guard owns(folder) else { return }
        try? FileManager.default.removeItem(at: folder.url)
    }

    /// Removes every action folder left from before (at launch). Returns how many were removed.
    @discardableResult
    public func removeLeftovers() -> Int {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: []
        ) else { return 0 }
        var removed = 0
        for child in children where (try? FileManager.default.removeItem(at: child)) != nil {
            removed += 1
        }
        return removed
    }

    /// Whether `folder` is an action folder of this scratch area: directly under `root`.
    public func owns(_ folder: ActionFolder) -> Bool {
        folder.url.standardizedFileURL.deletingLastPathComponent().path == root.path
            && !folder.url.lastPathComponent.isEmpty && folder.url.lastPathComponent != ".."
    }

    /// The JPEG's file name: the pressed file's stem with `.jpg`; "Photo.jpg" if the name has no usable stem. Path
    /// separators are never kept, so the name can't point outside its folder.
    public static func jpegName(forPressedName name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let stem = JPEGSourceRule.stem(of: last).trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty, stem != ".", stem != ".." else { return "Photo.jpg" }
        return stem + ".jpg"
    }
}
