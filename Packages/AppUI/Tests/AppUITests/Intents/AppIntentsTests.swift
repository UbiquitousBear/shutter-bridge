#if canImport(AppIntents)
import AppIntents
import Catalogue
import Foundation
import Testing
@testable import AppUI

// The intents themselves (I16), compiled and run only where App Intents exist (CI's iOS Simulator run). What they count,
// do and say is tested on Linux (NewPhotoCountTests, IntentsAppModelTests); these check that the entity carries the
// camera's key and name and that the intents keep the wording's titles, which they write as literals for the App
// Intents metadata.
@Suite("App Intents: the camera entity and the intents")
struct AppIntentsTests {
    @Test func theEntityIsTheCamerasKeyAndNameOnly() {
        let camera = IntentCamera(key: CameraKey(rawValue: "usb-mtp-device:hash"), name: "ILCE-7CM2", lastConnected: nil)
        let entity = CameraEntity(camera, now: Date())
        #expect(entity.id == "usb-mtp-device:hash")
        #expect(entity.key == camera.key)
        #expect(entity.name == "ILCE-7CM2")
        #expect(entity.detail == "Connected now")
    }

    @Test func theIntentsCarryTheirCamera() {
        let entity = CameraEntity(id: "usb-mtp-device:hash", name: "ILCE-7CM2", detail: "Connected now")
        #expect(ImportNewPhotosIntent(camera: entity).camera.id == entity.id)
        #expect(NewPhotoCountIntent(camera: entity).camera.id == entity.id)
    }

    @Test func theTitlesAreTheWordings() {
        #expect(String(localized: ImportNewPhotosIntent.title) == NewPhotosWording.importTitle)
        #expect(String(localized: NewPhotoCountIntent.title) == NewPhotosWording.countTitle)
    }
}
#endif
