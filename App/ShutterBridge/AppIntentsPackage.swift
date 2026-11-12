import AppIntents
import AppUI

/// Lists AppUI's App Intents package so the system finds the intents, the camera entity and the App Shortcuts declared
/// there (I16): App Intents in a Swift package are registered from the app target this way.
struct ShutterBridgeIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [AppUIIntentsPackage.self] }
}
