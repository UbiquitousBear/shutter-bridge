#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && os(iOS)
import CameraTransport
import SwiftUI
import UIKit

/// The Cameras screen (backlog section 6): the connected cameras with a USB-C badge and the mode in the camera's
/// wording, the empty state, a clear message when ImageCaptureCore's access is off, and another with Try Again when
/// discovery couldn't start at all (so it isn't taken for "No Camera Connected"). Its toolbar opens Settings.
/// While a job exists, the same import strip as on Browse sits at the top and opens the Import screen.
struct CamerasScreen: View {
    let model: CamerasModel
    var importer: ImportModel?
    var showSettings: @MainActor () -> Void = {}
    var showImport: @MainActor () -> Void = {}
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .navigationTitle(CamerasWording.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings()
                    } label: {
                        Label(CamerasWording.settingsButton, systemImage: "gearshape")
                    }
                }
            }
            .safeAreaBar(edge: .top) {
                StatusStrips {
                    if let notice = model.noticeStatus {
                        NoticeStrip(notice: notice) {
                            if model.noticeStatus == notice { model.notice = nil }
                        }
                    }
                    if let importer, importer.hasJob {
                        ImportStatusStrip(importer: importer, action: showImport)
                    }
                }
            }
            .animation(.default, value: model.noticeStatus)
            .animation(.default, value: importer?.hasJob)
            .onChange(of: model.noticeStatus) { _, notice in notice?.announcement.post() }
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
        } else if model.access == .failed {
            ContentUnavailableView {
                Label(CamerasWording.discoveryFailedTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(CamerasWording.discoveryFailedDetail)
            } actions: {
                Button(BrowseWording.tryAgain) {
                    let model = self.model
                    Task { await model.becameActive() }
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

/// A connected camera: its name, its mode and the USB-C badge. At the accessibility text sizes the row stacks, the
/// decorative symbol goes and the badge moves under the mode line, so the long MTP mode line isn't wrapped a word
/// per line (HIG Typography > Dynamic Type).
struct CameraRow: View {
    let camera: CameraDescriptor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            if !stacked {
                Image(systemName: "camera")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(CamerasWording.displayName(for: camera))
                    .font(.headline)
                Text(CamerasWording.modeLine(camera.mode))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !stacked {
                Spacer(minLength: 8)
            }
            if camera.carrier == .usb {
                // A fill, not a material: the row is solid, so there is nothing behind it to blur (HIG Materials).
                Label(CamerasWording.usbBadge, systemImage: "cable.connector")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// No camera: the cable and the mode to choose, short, with *Which USB Mode?* for the modes in detail (HIG Writing;
/// `ContentUnavailableView`: a short title, a brief description, an action for more).
struct CamerasEmptyView: View {
    let isLooking: Bool
    private let copy = CamerasEmptyState.standard
    @State private var showsModeHelp = false

    var body: some View {
        ContentUnavailableView {
            Label(copy.title, systemImage: "cable.connector")
        } description: {
            Text(copy.connect)
        } actions: {
            Button(copy.modeHelpButton) { showsModeHelp = true }
                .buttonStyle(.bordered)
            if isLooking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(CamerasEmptyState.lookingNotice)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showsModeHelp) {
            USBModeHelpSheet(copy: copy)
                .presentationDetents([.medium, .large])
        }
    }
}

/// The USB modes in detail: which to choose, why Remote Shoot (PC Remote) shows nothing, and what to do when the
/// camera doesn't ask. Nothing is confirmed here, so it closes with the system close button (HIG Sheets).
struct USBModeHelpSheet: View {
    let copy: CamerasEmptyState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(copy.modeHelpLines, id: \.self) { line in
                    Text(line)
                }
            }
            .navigationTitle(copy.modeHelpButton)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }
}
#endif
