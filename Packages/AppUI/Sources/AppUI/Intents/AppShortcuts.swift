#if canImport(AppIntents)
import AppIntents

// The App Shortcuts for the two intents (I16; backlog section 5, D7 (a): no third intent), and AppUI's App Intents
// package, which the app target lists (App/ShutterBridge/AppIntentsPackage.swift) so the intents declared in this
// package are found. Compiled only by CI's Xcode job. Every phrase names the app, as Siri requires; a phrase without the
// camera has Siri ask which (or take the only one, `CameraEntityQuery.defaultResult()`). Whether an App Shortcuts
// provider declared in a package rather than the app target reaches Siri is `unverified` (bench check 16).

/// Siri's and Spotlight's phrases for "Import new photos" and "How many new photos".
public struct ShutterBridgeShortcuts: AppShortcutsProvider, Sendable {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ImportNewPhotosIntent(),
            phrases: [
                "Import new photos from \(\.$camera) with \(.applicationName)",
                "Import new photos with \(.applicationName)",
                "Import photos from \(\.$camera) with \(.applicationName)",
            ],
            shortTitle: "Import New Photos",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: NewPhotoCountIntent(),
            phrases: [
                "How many new photos are on \(\.$camera) in \(.applicationName)",
                "How many new photos are on the camera in \(.applicationName)",
                "Check for new photos in \(.applicationName)",
            ],
            shortTitle: "New Photos",
            systemImageName: "photo.badge.plus"
        )
    }
}

/// AppUI's App Intents (the two intents, the camera entity and its query, the shortcuts), listed by the app target's
/// package so the system finds them in this package.
public struct AppUIIntentsPackage: AppIntentsPackage, Sendable {}
#endif
