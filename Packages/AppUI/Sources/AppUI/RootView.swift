#if canImport(SwiftUI)
import SwiftUI

/// The app's first screen: the catalogue opening, then Cameras with Browse pushed from it and the Import and Settings
/// screens over it (backlog section 6). The live screens need ImageCaptureCore, UIKit, Photos and SwiftData, so they
/// exist on iOS only; elsewhere (a Mac running `swift build`) this shows a line saying so.
public struct RootView: View {
    public init() {}

    public var body: some View {
        #if canImport(UIKit) && canImport(ImageCaptureCore) && canImport(Photos) && canImport(SwiftData) && os(iOS)
        LiveRoot()
        #else
        ContentUnavailableView(CamerasWording.title, systemImage: "cable.connector",
                               description: Text("Shutter Bridge reads cameras on iPhone."))
        #endif
    }
}
#endif
