#if DEBUG && canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && canImport(Photos) && canImport(SwiftData) && canImport(BackgroundTasks) && canImport(UserNotifications) && canImport(CoreBluetooth) && canImport(Network) && canImport(NetworkExtension) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers) && os(iOS)
import Foundation
import Photos
import PhotosBridge
import SwiftUI

// The app's half of the Photos lookup check (W6-lookup), Debug builds only: `RootView` shows `PhotosLookupCheckView`
// instead of the app when the process was started with `PhotosLookupCheck.launchArgument`. The check runs over the
// real library (`SystemPhotoLibrary`) with the UI test fixture's generated JPEGs, and reads the album's contents with
// Photos directly. Compiled and run only by CI's Xcode job (the UI tests in the iOS Simulator, with full Photos access
// granted to the app first).

/// The check's one screen: its report in one text, found by `PhotosLookupCheck.accessibilityIdentifier`.
struct PhotosLookupCheckView: View {
    @State private var report = PhotosLookupCheck.Report.running

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report.summary)
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityLabel(report.summary)
                    .accessibilityIdentifier(PhotosLookupCheck.accessibilityIdentifier)
            }
            // Verbatim: a Debug-only screen, kept out of the String Catalog.
            .navigationTitle(Text(verbatim: "Photos Lookup Check"))
        }
        .task {
            report = await PhotosLookupCheck.runInApp()
        }
    }
}

extension PhotosLookupCheck {
    /// The check over the real library, with a fresh token, its JPEGs in a temporary folder of its own.
    static func runInApp() async -> Report {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosLookupCheck", isDirectory: true)
        return await run(plan: Plan(token: Plan.makeToken(), now: Date()), library: SystemPhotoLibrary(),
                         folder: folder,
                         image: { index in UITestFixture.generatedJPEG(index) },
                         albumHolds: { album, asset in
                             Self.albumHolds(albumIdentifier: album, assetIdentifier: asset)
                         })
    }

    /// Whether the album with this `localIdentifier` holds the asset with that one: the album's assets fetched and
    /// compared by identifier (the album is new, so it holds one).
    static func albumHolds(albumIdentifier: String, assetIdentifier: String) -> Bool {
        let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumIdentifier], options: nil)
        guard let album = albums.firstObject else { return false }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        for index in 0 ..< assets.count where assets.object(at: index).localIdentifier == assetIdentifier {
            return true
        }
        return false
    }
}
#endif
