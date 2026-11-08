#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && os(iOS)
import CameraTransport
import SwiftUI
import UIKit

/// The live root on iPhone: the Cameras screen in a navigation stack, Browse pushed onto it. Discovery starts when
/// the app becomes active (and again after a refusal, in case access was turned on in Settings); temporary JPEG
/// folders left by a crash are removed once per launch.
struct LiveRoot: View {
    @State private var cameras = CamerasModel(discovery: USBCameraBrowser(), services: .system())
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $cameras.path) {
            CamerasScreen(model: cameras)
                .navigationDestination(for: CameraDescriptor.self) { camera in
                    BrowseScreen(model: cameras.browseModel(for: camera))
                }
        }
        .task { cameras.launch() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            Task { await cameras.becameActive() }
        }
    }
}

/// The Cameras screen (backlog section 6): the connected cameras with a USB-C badge and the mode in the camera's
/// wording, the empty state, and a clear message when ImageCaptureCore's access is off.
struct CamerasScreen: View {
    let model: CamerasModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .navigationTitle(CamerasWording.title)
            .safeAreaInset(edge: .top) {
                if let notice = model.notice {
                    NoticeStrip(text: notice) { model.notice = nil }
                        .padding(.horizontal)
                }
            }
            .animation(.default, value: model.notice)
    }

    @ViewBuilder private var content: some View {
        if model.access == .notAllowed {
            ContentUnavailableView {
                Label(CamerasWording.notAllowedTitle, systemImage: "lock")
            } description: {
                Text(CamerasWording.notAllowedDetail)
            } actions: {
                Button(CamerasWording.openSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.cameras.isEmpty {
            CamerasEmptyView(isLooking: model.isLooking)
        } else {
            List(model.cameras) { camera in
                NavigationLink(value: camera) {
                    CameraRow(camera: camera)
                }
            }
        }
    }
}

struct CameraRow: View {
    let camera: CameraDescriptor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.name)
                    .font(.headline)
                Text(CamerasWording.modeLine(camera.mode))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if camera.carrier == .usb {
                Label(CamerasWording.usbBadge, systemImage: "cable.connector")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct CamerasEmptyView: View {
    let isLooking: Bool
    private let copy = CamerasEmptyState.standard

    var body: some View {
        ContentUnavailableView {
            Label(copy.title, systemImage: "cable.connector")
        } description: {
            VStack(spacing: 12) {
                Text(copy.connect)
                Text(copy.modeAdvice)
                Text(copy.remoteShootNote)
            }
        } actions: {
            if isLooking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(CamerasEmptyState.lookingNotice)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// A one-line message with a close button, for the top of a screen.
struct NoticeStrip: View {
    let text: String
    var systemImage = "info.circle"
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .font(.subheadline)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
