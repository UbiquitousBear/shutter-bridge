import Foundation
import PTPKit

/// From the camera's ObjectInfo datasets to `CameraItem`s (backlog Iteration 3, section 2, *List*). Pure, so it is
/// tested on Linux.
///
/// GetObjectHandles with parent 0 lists every level of the card, folders included (on the α7C II the folders are
/// the handles that are multiples of 0x80000, by the spike's listings), so the folder path of each file comes from the
/// folders' own ObjectInfo in the same listing: no extra command. A file whose parent isn't among them (parent 0, or a
/// folder the listing didn't include) gets an empty folder, as an MTP item without a parent does over USB.
enum IPListing {
    /// One folder seen in a listing: its name and its parent.
    struct Folder: Sendable, Hashable {
        var name: String
        var parent: PTPObjectHandle
    }

    /// The deepest folder walk followed, against a loop in a faulty tree (as `USBListing` does).
    static let maximumFolderDepth = 16

    /// The folders among the datasets, by handle.
    static func folders(in infos: [(handle: PTPObjectHandle, info: PTPObjectInfo)]) -> [PTPObjectHandle: Folder] {
        var folders: [PTPObjectHandle: Folder] = [:]
        for (handle, info) in infos where info.isFolder {
            folders[handle] = Folder(name: info.filename, parent: info.parentObject)
        }
        return folders
    }

    /// "DCIM/100MSDCF" for a file whose parent is 100MSDCF inside DCIM. Empty names are dropped.
    static func folderPath(of parent: PTPObjectHandle, in folders: [PTPObjectHandle: Folder]) -> String {
        var names: [String] = []
        var current = parent
        var seen: Set<PTPObjectHandle> = []
        while names.count < maximumFolderDepth, let folder = folders[current], seen.insert(current).inserted {
            names.append(folder.name)
            current = folder.parent
        }
        return names.reversed().filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// Whether `name` is a plain file name, safe to write under in a folder of the phone: not empty, not `.` or `..`,
    /// and no `/` or NUL. The name comes from whatever answers at the camera's address, which on first pairing nothing
    /// has vouched for yet.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// One file, or nil for a folder, or a file whose name is empty or not a plain name (`isSafeFileName`): nothing
    /// can be imported or matched without one.
    ///
    /// The size is ObjectInfo's 32-bit field. For an object of 4 GiB or more the camera reports 0xFFFFFFFF (ISO
    /// 15740) and this session has no other source (it lists no object properties), so such a clip shows that
    /// value; video isn't imported in 1.0, and the download's own length is what is written.
    static func item(handle: PTPObjectHandle, info: PTPObjectInfo, folders: [PTPObjectHandle: Folder],
                     timeZone: TimeZone) -> CameraItem? {
        guard !info.isFolder, isSafeFileName(info.filename) else { return nil }
        return CameraItem(id: IPItemID.id(for: handle), folder: folderPath(of: info.parentObject, in: folders),
                          name: info.filename, size: UInt64(info.objectCompressedSize),
                          captureDate: PTPDateTime.parse(info.captureDateRaw, defaultTimeZone: timeZone),
                          format: info.mediaKind)
    }

    /// Every file in a listing, newest first, as Browse and the thumbnail queue want them.
    static func items(from infos: [(handle: PTPObjectHandle, info: PTPObjectInfo)], timeZone: TimeZone) -> [CameraItem] {
        let folders = folders(in: infos)
        return infos.compactMap { item(handle: $0.handle, info: $0.info, folders: folders, timeZone: timeZone) }
            .newestFirst()
    }
}
