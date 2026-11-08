#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && canImport(Photos) && canImport(SwiftData) && os(iOS)
import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import SwiftUI
import UIKit

// The composition root's Apple-only half (backlog section 6): the real catalogue, engine, Photos library, Files
// folder, discovery and camera key, handed to `AppModel`, and the root view that opens the catalogue first. The plain
// half (`AppModel`, `AppLauncher`) is tested on Linux with fakes.

extension AppLauncher {
    /// The app's launcher. Nothing is opened here: `launch()` opens the catalogue (off the main actor, as
    /// `SwiftDataCatalogue.open(storeURL:)` does by itself) and then builds the app around it.
    static func live() -> AppLauncher {
        AppLauncher(
            openCatalogue: { try await SwiftDataCatalogue.open(storeURL: SwiftDataCatalogue.defaultStoreURL) },
            build: { catalogue in AppModel.live(catalogue: catalogue) },
            log: OSLogBenchLog()
        )
    }
}

extension AppModel {
    /// The app's models over the opened catalogue:
    ///
    /// - one `ImportEngine` with it, staging under the temporary folder (`tmp/Imports`, the engine's default, which it
    ///   empties at start-up);
    /// - Photos through `SystemPhotoLibrary` (`PhotosLibraryDestination`, one album per camera by default), and the
    ///   Files folder under Documents, one folder per camera (`FilesFolderDestination`), which the Info.plist shows in
    ///   Files as On My iPhone › Shutter Bridge;
    /// - the destination setting and the album identifiers in `UserDefaults`;
    /// - discovery through `USBCameraBrowser`, and the camera key from the USB link's key material (`CameraKeys`:
    ///   hashed device UUID in MTP, mode and volume name in MSC; unverified, backlog sections 2 and 4).
    static func live(catalogue: any CatalogueStore) -> AppModel {
        let library = SystemPhotoLibrary()
        let engine = ImportEngine(catalogue: catalogue)
        let destinations = StandardImportDestinations(
            library: library,
            albumStore: UserDefaultsAlbumIdentifierStore(),
            metadata: ImageIOMetadataReader(),
            documentsDirectory: URL.documentsDirectory
        )
        return AppModel(
            discovery: USBCameraBrowser(),
            services: .system(),
            catalogue: catalogue,
            engine: engine,
            settingsStore: UserDefaultsDestinationSettingStore(),
            photos: LibraryPhotosAuthorisation(library: library),
            destinations: destinations,
            cameraKey: { descriptor, link in
                guard let usb = link as? USBLink else { return CameraKeys.key(for: descriptor, material: nil) }
                let material = await usb.cameraKeyMaterial()
                return CameraKeys.key(for: descriptor, material: material?.rawValue)
            }
        )
    }
}

extension AppScenePhase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        case .inactive: self = .inactive
        @unknown default: self = .inactive
        }
    }
}

/// The live root on iPhone: opens the catalogue, then shows the app; if the catalogue can't be opened, a clear error
/// with Try Again instead of a crash.
struct LiveRoot: View {
    @State private var launcher = AppLauncher.live()

    var body: some View {
        Group {
            switch launcher.state {
            case .opening:
                ProgressView(AppWording.openingCatalogue)
            case let .ready(model):
                LiveApp(model: model)
            case .failed:
                ContentUnavailableView {
                    Label(AppWording.catalogueFailedTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(AppWording.catalogueFailedDetail)
                } actions: {
                    Button(AppWording.tryAgain) {
                        Task { await launcher.launch() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await launcher.launch() }
    }
}

/// The app once the catalogue is open: Cameras in a navigation stack with Browse pushed onto it, and the Import and
/// Settings screens as sheets over the whole stack, so the Import screen outlives Browse when the cable is pulled.
///
/// - The scene's phase goes to the app model in order (discovery starts when active; a USB import pauses when the
///   app leaves the foreground and carries on when it is back, decision 1).
/// - The screen stays on while a USB import runs (`UIApplication.isIdleTimerDisabled`), and goes back to normal
///   otherwise.
struct LiveApp: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSettings = false
    @State private var showsImport = false
    /// The last scene-phase change handed to the model, so a quick background-then-active is applied in order.
    @State private var phaseTask: Task<Void, Never>?

    var body: some View {
        @Bindable var cameras = model.cameras
        NavigationStack(path: $cameras.path) {
            CamerasScreen(model: cameras, importer: model.importer,
                          showSettings: { showsSettings = true },
                          showImport: { showsImport = true })
                .navigationDestination(for: CameraDescriptor.self) { camera in
                    BrowseScreen(model: model.browseModel(for: camera), importer: model.importer,
                                 showImport: { showsImport = true })
                }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsScreen(model: model.settings)
        }
        .sheet(isPresented: $showsImport) {
            ImportScreen(model: model.importer)
        }
        .task { model.cameras.launch() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let previous = phaseTask
            let model = self.model
            let appPhase = AppScenePhase(phase)
            phaseTask = Task {
                await previous?.value
                await model.scenePhaseChanged(appPhase)
            }
        }
        .onChange(of: model.keepsScreenOn, initial: true) { _, keepsOn in
            UIApplication.shared.isIdleTimerDisabled = keepsOn
        }
    }
}
#endif
