import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

@MainActor
@Suite("Settings: the remembered choice, where it is kept, and where staging goes")
struct SettingsTests {
    @Test func theDefaultIsImportToPhotos() {
        let suite = TemporaryDefaults()
        defer { suite.drop() }
        #expect(UserDefaultsDestinationSettingStore(defaults: suite.defaults).load() == .default)
        #expect(DestinationSetting.default.preferred == .photos)
    }

    @Test func theChoiceIsSavedAndReadBack() {
        let suite = TemporaryDefaults()
        defer { suite.drop() }
        UserDefaultsDestinationSettingStore(defaults: suite.defaults).save(DestinationSetting(preferred: .staging))
        // A later launch reads it back.
        #expect(UserDefaultsDestinationSettingStore(defaults: suite.defaults).load().preferred == .staging)
        UserDefaultsDestinationSettingStore(defaults: suite.defaults).save(DestinationSetting(preferred: .photos))
        #expect(UserDefaultsDestinationSettingStore(defaults: suite.defaults).load().preferred == .photos)
    }

    /// Someone who had chosen Files in an earlier build gets Stage as the remembered choice (Shamil, 11 Nov), and
    /// the Import button says so.
    @Test func anEarlierBuildsFilesSettingReadsAsStage() async {
        let suite = TemporaryDefaults()
        defer { suite.drop() }
        suite.defaults.set(Data(#"{"preferred":"filesFolder"}"#.utf8), forKey: UserDefaultsDestinationSettingStore.key)
        let store = UserDefaultsDestinationSettingStore(defaults: suite.defaults)
        #expect(store.load() == DestinationSetting(preferred: .staging))
        let catalogue = InMemoryCatalogue()
        let model = ImportModel(engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                                settings: store, photos: FakePhotosAccess(), destinations: FakeDestinations())
        #expect(model.importChoice == .staging)
        #expect(BrowseWording.importButtonTitle(model.importChoice) == "Stage")
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

    @Test func copy() {
        let footer = SettingsWording.stagingFooter
        #expect(footer.contains("a folder for each camera and capture day"))
        #expect(footer.contains("leaves Photos alone"))
        #expect(footer.contains("Import to Photos or Stage"))
        // Nothing promised that isn't built yet, and what Photos access does is said in its own row.
        #expect(!footer.lowercased().contains("cull"))
        #expect(!footer.contains("Photos access"))
        #expect(SettingsWording.stagingHeader == "Staging")
        #expect(SettingsWording.forcedStaging(.chosen) == nil)
        #expect(SettingsWording.forcedStaging(.photosDenied)
            == "Photos access is off, so Import to Photos stages the photos instead.")
        #expect(SettingsWording.forcedStaging(.photosRestricted)
            == "Photos is restricted on this iPhone, so Import to Photos stages the photos instead.")
        #expect(SettingsWording.stagingLocation(.iCloudDrive) == "iCloud Drive › Shutter Bridge › Staging")
        #expect(SettingsWording.stagingLocation(.onThisIPhone(.iCloudDriveOff))
            == "On My iPhone › Shutter Bridge › Staging")
        #expect(SettingsWording.stagingLocationAccessibility(.iCloudDrive)
            == "Staging folder, iCloud Drive › Shutter Bridge › Staging")
        #expect(SettingsWording.stagingFallback(.iCloudDrive) == nil)
        #expect(SettingsWording.stagingFallback(.onThisIPhone(.iCloudDriveOff))
            == "iCloud Drive is off or you're not signed in to iCloud, so staging is on this iPhone.")
        #expect(SettingsWording.stagingFallback(.onThisIPhone(.containerUnavailable))
            == "iCloud Drive isn't available to Shutter Bridge, so staging is on this iPhone.")
    }

    @Test func settingsSaysWhereStagingGoesAndWhy() async {
        let locator = FakeStagingLocator(.unavailable(.iCloudDriveOff))
        let model = SettingsModel(staging: locator)
        // Not read yet: nothing said.
        #expect(model.stagingPlace == nil)
        #expect(model.stagingLocation == nil)
        #expect(model.stagingFallbackLine == nil)
        await model.refresh()
        #expect(model.stagingPlace == .onThisIPhone(.iCloudDriveOff))
        #expect(model.stagingLocation == "On My iPhone › Shutter Bridge › Staging")
        #expect(model.stagingFallbackLine
            == "iCloud Drive is off or you're not signed in to iCloud, so staging is on this iPhone.")
        // Signed in meanwhile: read again on return to the app.
        await locator.set(.iCloudDrive(documents: URL(fileURLWithPath: "/nonexistent/iCloud/Documents")))
        await model.refresh()
        #expect(model.stagingPlace == .iCloudDrive)
        #expect(model.stagingLocation == "iCloud Drive › Shutter Bridge › Staging")
        #expect(model.stagingFallbackLine == nil)
        #expect(await locator.locateCount == 2)
    }

    @Test func withoutALocatorNothingIsSaidAboutStaging() async {
        let model = SettingsModel()
        await model.refresh()
        #expect(model.stagingPlace == nil)
        #expect(model.stagingLocation == nil)
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

    /// The app's keying (`LiveRoot`): every link to one device in MTP gives the same key, whatever the link, and
    /// links without material fall back to the mode and name.
    @Test func keyingGivesOneKeyPerDeviceOnEveryLink() async {
        let material = "00000000-0000-0000-0000-00000000ABCD"   // made up, not a device's
        let keying = CameraKeys.keying(material: { link in
            link.descriptor.mode == .usb(.mtp) ? material : nil
        })
        let mtp = CameraDescriptor(id: .init(rawValue: "a"), name: "ILCE-7CM2", mode: .usb(.mtp))
        let first = await keying(mtp, FakeLink(items: [], mode: .usb(.mtp), id: "one"))
        let second = await keying(mtp, FakeLink(items: [], mode: .usb(.mtp), id: "two"))
        #expect(first == second)
        #expect(first == CameraKeys.key(for: mtp, material: material))
        let msc = CameraDescriptor(id: .init(rawValue: "b"), name: "Untitled", mode: .usb(.massStorage))
        let mscLink = FakeLink(items: [], mode: .usb(.massStorage), id: "three")
        #expect(await keying(msc, mscLink) == CameraKeys.key(for: msc, material: nil))
        #expect(await CameraKeys.keying(material: { _ in nil })(mtp, FakeLink(items: [], id: "four"))
            == CameraKeys.key(for: mtp, material: nil))
    }

    @Test func tagsNameKeysWithoutTheirValue() {
        let tags = CameraKeyTags()
        let mtp = CameraKeys.key(for: CameraDescriptor(id: .init(rawValue: "a"), name: "ILCE-7CM2", mode: .usb(.mtp)),
                                 material: "00000000-0000-0000-0000-00000000ABCD")
        let msc = CameraKeys.key(for: CameraDescriptor(id: .init(rawValue: "b"), name: "Untitled",
                                                       mode: .usb(.massStorage)), material: nil)
        let odd = CameraKey(rawValue: "serial-0001:something")
        #expect(tags.tag(for: mtp) == "k1 (usb-device)")
        #expect(tags.tag(for: msc) == "k2 (usb-msc-name)")
        #expect(tags.tag(for: mtp) == "k1 (usb-device)")   // stable within the launch
        #expect(tags.tag(for: odd) == "k3 (other)")
        #expect(tags.tag(for: CameraKey(rawValue: "")) == "k4 (other)")
        for key in [mtp, msc, odd] {
            let tag = tags.tag(for: key)
            let value = String(key.rawValue.drop { $0 != ":" }.dropFirst())
            #expect(!tag.contains(value.prefix(4)), "\(tag)")
            #expect(!tag.contains("serial"))
        }
    }
}
