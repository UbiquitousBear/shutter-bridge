#if DEBUG && canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && canImport(Photos) && canImport(SwiftData) && canImport(BackgroundTasks) && canImport(UserNotifications) && canImport(CoreBluetooth) && canImport(Network) && canImport(NetworkExtension) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers) && os(iOS)
import Catalogue
import CoreGraphics
import Foundation
import ImageIO
import ImportEngine
import PhotosBridge
import UniformTypeIdentifiers

// The app's half of the UI tests' seeded app (I18; D14 (c)), Debug builds only: `LiveLaunch` uses it instead of the
// live launcher when the process was started with `UITestFixture.launchArgument`. The catalogue is an `InMemoryCatalogue`
// seeded by `UITestFixture`, the staged files are JPEGs drawn here, and the app around it has no camera discovery
// (`CompositeDiscovery` with no sources), no Wi-Fi or Bluetooth, Photos access that reads as allowed without asking, and
// staging on this iPhone in the fixture's folder. No `PTPSimulator`: nothing here talks to a camera.

extension AppLauncher {
    /// The UI tests' launcher: seeds the fixture (emptying its folder first), then builds the app around it.
    static func uiTestFixture() -> AppLauncher {
        AppLauncher(
            openCatalogue: {
                let catalogue: any CatalogueStore = try await UITestFixture.makeCatalogue(
                    documents: UITestFixture.documents, now: Date(), image: UITestFixture.generatedJPEG)
                return catalogue
            },
            build: { catalogue in AppModel.uiTestFixture(catalogue: catalogue) },
            log: AppLogging.shared.log
        )
    }
}

extension AppModel {
    /// The app's models over the fixture's catalogue: the engine with its work folder in the fixture's folder, the
    /// destinations with staging on this iPhone (iCloud Drive reads as off, so Settings' Staging section always says the
    /// same), no discovery, Photos access allowed, and the diagnostics export as the app has it.
    static func uiTestFixture(catalogue: any CatalogueStore) -> AppModel {
        let logging = AppLogging.shared
        let engine = ImportEngine(catalogue: catalogue, stagingDirectory: UITestFixture.workFolder,
                                  trace: .bench(logging.log))
        // The launch pass, as the live app runs it.
        Task { await engine.reconcilePartials() }
        let destinations = StandardImportDestinations(
            library: SystemPhotoLibrary(),
            albumStore: InMemoryAlbumIdentifierStore(),
            documentsDirectory: UITestFixture.documents,
            stagingLocator: FakeStagingLocator(.unavailable(.iCloudDriveOff)),
            iCloudDriveMover: PlainFileMover()
        )
        return AppModel(
            discovery: CompositeDiscovery(sources: []),
            services: .system(log: logging.log),
            catalogue: catalogue,
            engine: engine,
            settingsStore: InMemoryDestinationSettingStore(),
            photos: UITestPhotosAccess(),
            destinations: destinations,
            cameraKey: CameraKeys.keying(material: { _ in nil }),
            diagnostics: logging.exporter(catalogue: catalogue)
        )
    }
}

extension UITestFixture {
    /// A staged photo for the fixture: a 1200 × 800 JPEG in a colour of its own with a light band whose place follows
    /// `index`, so the loupe's photos differ. Drawn with Core Graphics and written with ImageIO, off the main actor.
    /// Empty if drawing fails, which the cull screen shows as a photo it couldn't read.
    static func generatedJPEG(_ index: Int) -> Data {
        let width = 1_200
        let height = 800
        let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.80, 0.33, 0.24), (0.20, 0.50, 0.78), (0.28, 0.62, 0.36),
                                                      (0.88, 0.68, 0.20)]
        let colour = colours[index % colours.count]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return Data() }
        context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.4)
        context.fill(CGRect(x: 100 + (index % 5) * 200, y: 200, width: 200, height: 400))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil)
        else { return Data() }
        let options = [kCGImageDestinationLossyCompressionQuality as String: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }
}

/// Photos access that reads as allowed and never asks, so no system prompt covers the screens under test.
private struct UITestPhotosAccess: PhotosAuthorising {
    func authorisation() async -> PhotosAuthorisation { .authorised }
    func requestReadWriteAuthorisation() async -> PhotosAuthorisation { .authorised }
}
#endif
