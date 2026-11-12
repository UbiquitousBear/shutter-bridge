#if canImport(AppIntents)
import AppIntents
import Foundation

/// "Import new photos from <camera>" (I16; backlog section 5, D7 (a)). Compiled only by CI's Xcode job; what it does
/// is `AppModel.importNewPhotos(cameraWith:waitingForCamera:waitingForImport:)` and what it says is
/// `NewPhotosWording.importAnswer(_:camera:)`, both tested on Linux.
///
/// It opens the app before it runs (both links need the app in front: a USB import pauses away from it, and a Wi-Fi
/// join needs it), opens Browse on the camera, and starts what *Select All New* then *Import* start there, with the
/// remembered Import-button choice (Photos or Stage). Photos access, when it was never asked, is asked for in the app as
/// *Import* asks it. It never joins Wi-Fi from the background.
public struct ImportNewPhotosIntent: AppIntent {
    public static var title: LocalizedStringResource { "Import New Photos" }
    public static var description: IntentDescription? {
        // One literal: the App Intents metadata is read from it at build time.
        IntentDescription("Opens Shutter Bridge and imports the camera's new photos, to Photos or to Staging as the Import button last did.")
    }

    /// In front before it runs (iOS 26's replacement for `openAppWhenRun`).
    public static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Camera", requestValueDialog: "Which camera?")
    public var camera: CameraEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Import new photos from \(\.$camera)")
    }

    public init() {}

    public init(camera: CameraEntity) {
        self.camera = camera
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let camera = self.camera
        guard let model = await IntentHost.model() else {
            return .result(dialog: "\(NewPhotosWording.importAnswer(.appNotReady, camera: camera.name))")
        }
        let start = await model.importNewPhotos(cameraWith: camera.key)
        return .result(dialog: "\(NewPhotosWording.importAnswer(start, camera: camera.name))")
    }
}
#endif
