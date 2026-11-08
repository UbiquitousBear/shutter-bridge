import Foundation
import Testing
@testable import AppUI

@Suite("Copy as JPEG: temporary folders")
struct JPEGScratchTests {
    @Test func oneFolderPerActionWithCameraAndJPEGInside() throws {
        let scratch = temporaryScratch()
        let id = UUID()
        let folder = try scratch.makeActionFolder(id: id)
        #expect(folder.url.lastPathComponent == id.uuidString)
        #expect(folder.url.deletingLastPathComponent().standardizedFileURL.path == scratch.root.path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.download.path, isDirectory: &isDirectory)
            && isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: folder.output.path, isDirectory: &isDirectory)
            && isDirectory.boolValue)
        #expect(folder.outputFile(forPressedName: "DSC00001.ARW").lastPathComponent == "DSC00001.jpg")
        #expect(folder.outputFile(forPressedName: "DSC00001.ARW").deletingLastPathComponent().lastPathComponent
            == "jpeg")
        #expect(scratch.owns(folder))
    }

    @Test func removeTakesTheWholeFolderAndNothingOutsideTheRoot() throws {
        let scratch = temporaryScratch()
        let folder = try scratch.makeActionFolder()
        try Data("x".utf8).write(to: folder.download.appendingPathComponent("DSC00001.ARW"))
        scratch.remove(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))

        // A folder elsewhere is left alone, even one named like an action folder.
        let elsewhere = scratch.root.deletingLastPathComponent().appendingPathComponent("Keep", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let stranger = JPEGScratch.ActionFolder(url: elsewhere)
        #expect(!scratch.owns(stranger))
        scratch.remove(stranger)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
        #expect(!scratch.owns(JPEGScratch.ActionFolder(url: scratch.root)))
    }

    @Test func leftoversAreRemovedAtLaunch() throws {
        let scratch = temporaryScratch()
        #expect(scratch.removeLeftovers() == 0)   // no root yet
        _ = try scratch.makeActionFolder()
        _ = try scratch.makeActionFolder()
        #expect(actionFolders(in: scratch).count == 2)
        #expect(scratch.removeLeftovers() == 2)
        #expect(actionFolders(in: scratch).isEmpty)
    }

    @Test func theJPEGIsNamedAfterThePressedFile() {
        #expect(JPEGScratch.jpegName(forPressedName: "DSC00001.ARW") == "DSC00001.jpg")
        #expect(JPEGScratch.jpegName(forPressedName: "DSC00001.JPG") == "DSC00001.jpg")
        #expect(JPEGScratch.jpegName(forPressedName: "DSC00001.HIF") == "DSC00001.jpg")
        #expect(JPEGScratch.jpegName(forPressedName: "../../etc/passwd") == "passwd.jpg")
        #expect(JPEGScratch.jpegName(forPressedName: "") == "Photo.jpg")
        #expect(JPEGScratch.jpegName(forPressedName: "..") == "Photo.jpg")
        #expect(JPEGScratch.jpegName(forPressedName: "dir/") == "dir.jpg")
    }

    @Test func theCachesFolder() {
        #expect(JPEGScratch.inCaches().root.lastPathComponent == JPEGScratch.folderName)
    }
}
