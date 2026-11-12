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
        // The date keeps the zone it was made in, so an item `list(reusing:)` keeps from before a time-zone change
        // still reads back as the camera's own time.
        let capture = CameraItem.captureTime(ptpDateTime: info.captureDateRaw, defaultTimeZone: timeZone)
        return CameraItem(id: IPItemID.id(for: handle), folder: folderPath(of: info.parentObject, in: folders),
                          name: info.filename, size: UInt64(info.objectCompressedSize),
                          captureDate: capture?.date, format: info.mediaKind, captureTimeZone: capture?.zone)
    }

    /// What a relist can take from items it listed before (`IPLink.list(reusing:)`): handles were stable across
    /// sessions on the bench (backlog B:91), so a known item whose handle is listed again is kept as it was, and only
    /// the handles not among them need GetObjectInfo (`SonyHandleSet.unseen`). Folders are never items, so their
    /// handles are always unseen and their ObjectInfo is always read: new files get their folder paths.
    ///
    /// Known items that aren't this link's (no handle in the ID), or whose name isn't a plain file name, are not kept;
    /// the first of two items naming one handle wins.
    ///
    /// - Returns: The kept items by handle (only handles listed now), and the listed handles not among them, in
    ///   listing order.
    static func reuse(_ known: [CameraItem], listed handles: [PTPObjectHandle])
        -> (kept: [PTPObjectHandle: CameraItem], unseen: [PTPObjectHandle]) {
        var byHandle: [PTPObjectHandle: CameraItem] = [:]
        var order: [UInt32] = []
        for item in known {
            guard let handle = IPItemID.handle(of: item.id), isSafeFileName(item.name), byHandle[handle] == nil
            else { continue }
            byHandle[handle] = item
            order.append(handle.rawValue)
        }
        let previous = SonyHandleSet(order)
        let current = SonyHandleSet(handles.map(\.rawValue))
        let unseen = previous.unseen(in: current).map(PTPObjectHandle.init(rawValue:))
        let kept = byHandle.filter { current.contains($0.key.rawValue) }
        return (kept, unseen)
    }

    /// Every file in a listing, newest first, as Browse and the thumbnail queue want them.
    static func items(from infos: [(handle: PTPObjectHandle, info: PTPObjectInfo)], timeZone: TimeZone) -> [CameraItem] {
        let folders = folders(in: infos)
        return infos.compactMap { item(handle: $0.handle, info: $0.info, folders: folders, timeZone: timeZone) }
            .newestFirst()
    }
}
