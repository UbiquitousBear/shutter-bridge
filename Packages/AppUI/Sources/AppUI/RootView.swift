#if canImport(SwiftUI)
import SwiftUI

/// The app's first screen: the catalogue opening, then the tab bar (Iteration 2, I10): Cameras with Browse pushed from
/// it, Staging and History, the running import as the bar's bottom accessory, and the Import and Settings screens over
/// it all (`LiveApp`; backlog section 6 of Iteration 1, section 4 of Iteration 2). The live screens need
/// ImageCaptureCore, UIKit, Photos and SwiftData, so they exist on iOS only; elsewhere (a Mac running `swift build`) this
/// shows a line saying so.
public struct RootView: View {
    public init() {}

    public var body: some View {
        #if canImport(UIKit) && canImport(ImageCaptureCore) && canImport(Photos) && canImport(SwiftData) && canImport(BackgroundTasks) && canImport(UserNotifications) && canImport(CoreBluetooth) && canImport(Network) && canImport(NetworkExtension) && os(iOS)
        #if DEBUG && canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        // The Photos lookup check (W6-lookup) in a Debug build started with its launch argument; the app otherwise.
        if PhotosLookupCheck.isRequested() {
            PhotosLookupCheckView()
        } else {
            LiveRoot()
        }
        #else
        LiveRoot()
        #endif
        #else
        ContentUnavailableView(CamerasWording.title, systemImage: "cable.connector",
                               description: Text("Shutter Bridge reads cameras on iPhone."))
        #endif
    }
}
#endif
