#if canImport(SwiftUI)
import SwiftUI

/// The app's first screen: Cameras, and Browse pushed from it (backlog section 6, the thin slice of 8 Nov). The
/// live screens need ImageCaptureCore and UIKit, so they exist on iOS only; elsewhere (a Mac running `swift build`)
/// this shows a line saying so.
public struct RootView: View {
    public init() {}

    public var body: some View {
        #if canImport(ImageCaptureCore) && canImport(UIKit) && os(iOS)
        LiveRoot()
        #else
        ContentUnavailableView(CamerasWording.title, systemImage: "cable.connector",
                               description: Text("Shutter Bridge reads cameras on iPhone."))
        #endif
    }
}
#endif
