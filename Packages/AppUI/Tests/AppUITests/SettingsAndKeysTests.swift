import CameraTransport
import Catalogue
import Foundation
import PhotosBridge
import Testing
@testable import AppUI

@MainActor
@Suite("Settings: the destination setting and where it is kept")
struct SettingsTests {
    @Test func theDefaultIsPhotos() {
        let suite = TemporaryDefaults()
        defer { suite.drop() }
        #expect(UserDefaultsDestinationSettingStore(defaults: suite.defaults).load() == .default)
        #expect(SettingsModel(store: InMemoryDestinationSettingStore()).destination == .photos)
    }

    @Test func theSettingIsSavedAndReadBack() {
        let suite = TemporaryDefaults()
        defer { suite.drop() }
        let model = SettingsModel(store: UserDefaultsDestinationSettingStore(defaults: suite.defaults))
        model.destination = .filesFolder
        // A later launch reads it back.
        #expect(UserDefaultsDestinationSettingStore(defaults: suite.defaults).load().preferred == .filesFolder)
        #expect(SettingsModel(store: UserDefaultsDestinationSettingStore(defaults: suite.defaults)).destination
            == .filesFolder)
        model.destination = .photos
        #expect(UserDefaultsDestinationSettingStore(defaults: suite.defaults).load().preferred == .photos)
    }

    @Test func anUnreadableOrUnknownValueReadsAsPhotos() {
        let suite = TemporaryDefaults()
        defer { suite.drop() }
        let store = UserDefaultsDestinationSettingStore(defaults: suite.defaults)
        suite.defaults.set(Data("not json".utf8), forKey: UserDefaultsDestinationSettingStore.key)
        #expect(store.load() == .default)
        suite.defaults.set(Data(#"{"preferred":"cloud"}"#.utf8), forKey: UserDefaultsDestinationSettingStore.key)
        #expect(store.load() == .default)
    }

    @Test func choicesAndCopy() {
        #expect(SettingsModel.choices == [.photos, .filesFolder])
        #expect(SettingsModel.label(for: .photos) == "Photos")
        #expect(SettingsModel.label(for: .filesFolder) == "Files")
        let footer = SettingsWording.destinationFooter
        #expect(footer.contains("Photos access is off"))
        #expect(footer.contains("restricted"))
        #expect(footer.contains("On My iPhone › Shutter Bridge"))
        #expect(footer.contains("a folder for each camera"))
    }

    @Test func albumIdentifiersAreKeptPerKey() async {
        let suite = TemporaryDefaults()
        defer { suite.drop() }
        let store = UserDefaultsAlbumIdentifierStore(defaults: suite.defaults)
        #expect(await store.albumIdentifier(forKey: "camera:a") == nil)
        await store.setAlbumIdentifier("album-1", forKey: "camera:a")
        await store.setAlbumIdentifier("album-2", forKey: "import:b")
        let again = UserDefaultsAlbumIdentifierStore(defaults: suite.defaults)
        #expect(await again.albumIdentifier(forKey: "camera:a") == "album-1")
        #expect(await again.albumIdentifier(forKey: "import:b") == "album-2")
        await again.setAlbumIdentifier(nil, forKey: "camera:a")
        #expect(await store.albumIdentifier(forKey: "camera:a") == nil)
        #expect(await store.albumIdentifier(forKey: "import:b") == "album-2")
    }
}

@Suite("Camera keys")
struct CameraKeysTests {
    @Test func sha256KnownAnswers() {
        #expect(SHA256Digest.hex(of: Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two blocks.
        #expect(SHA256Digest.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func mtpMaterialIsHashedNeverKept() {
        let camera = CameraDescriptor(id: .init(rawValue: "x"), name: "ILCE-7CM2", mode: .usb(.mtp))
        let material = "00000000-0000-0000-0000-00000000ABCD"   // a made-up UUID, not a device's
        let key = CameraKeys.key(for: camera, material: material)
        #expect(!key.rawValue.contains(material))
        #expect(!key.rawValue.contains("ABCD"))
        #expect(key.rawValue.hasPrefix("usb-device:"))
        #expect(key == CameraKeys.key(for: camera, material: material))   // stable
        #expect(key != CameraKeys.key(for: camera, material: material + "0"))
        // The device keys the camera, whatever it is called.
        var renamed = camera
        renamed.name = "Other"
        #expect(CameraKeys.key(for: renamed, material: material) == key)
    }

    @Test func mscFallsBackToTheModeAndTheName() {
        let msc = CameraDescriptor(id: .init(rawValue: "1"), name: "Untitled", mode: .usb(.massStorage))
        let mscAgain = CameraDescriptor(id: .init(rawValue: "2"), name: "Untitled", mode: .usb(.massStorage))
        let mtp = CameraDescriptor(id: .init(rawValue: "1"), name: "Untitled", mode: .usb(.mtp))
        #expect(CameraKeys.key(for: msc, material: nil) == CameraKeys.key(for: mscAgain, material: nil))
        #expect(CameraKeys.key(for: msc, material: nil) != CameraKeys.key(for: mtp, material: nil))
        #expect(CameraKeys.key(for: msc, material: "") == CameraKeys.key(for: msc, material: nil))
        #expect(!CameraKeys.key(for: msc, material: nil).rawValue.contains("Untitled"))
    }
}
