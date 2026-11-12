#if canImport(AppIntents)
import AppIntents
import Foundation

/// "How many new photos are on <camera>?" (I16; backlog section 5, D7 (a)). Compiled only by CI's Xcode job; what it
/// counts is `AppModel.newPhotoCount(cameraWith:)` (`NewPhotoCount`) and what it says is
/// `NewPhotosWording.countAnswer(_:camera:now:calendar:locale:)`, both tested on Linux.
///
/// It runs without opening the app and opens no link: it answers from the catalogue's last listing of the card, with its
/// age ("12 new photos when the card was last read, today at 14:05."), or from the live card while a USB camera is
/// connected and listed in Browse. It counts what *Select All New* would pick: stills with a capture date that are
/// neither imported, staged nor rejected. The number also goes to Shortcuts (0 when there is nothing to count).
public struct NewPhotoCountIntent: AppIntent {
    public static var title: LocalizedStringResource { "How Many New Photos" }
    public static var description: IntentDescription? {
        IntentDescription("Says how many new photos are on the camera's card, from the last time Shutter Bridge read it.")
    }

    @Parameter(title: "Camera", requestValueDialog: "Which camera?")
    public var camera: CameraEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("How many new photos are on \(\.$camera)")
    }

    public init() {}

    public init(camera: CameraEntity) {
        self.camera = camera
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let camera = self.camera
        let answer: NewPhotoCountAnswer
        if let model = await IntentHost.model() {
            answer = await model.newPhotoCount(cameraWith: camera.key)
        } else {
            answer = .unavailable
        }
        let text = NewPhotosWording.countAnswer(answer, camera: camera.name, now: Date())
        return .result(value: answer.count, dialog: "\(text)")
    }
}
#endif
