import AppUI
import SwiftUI

/// The app target is only this shim and its resources; everything else lives in the packages (AGENTS.md).
@main
struct ShutterBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
