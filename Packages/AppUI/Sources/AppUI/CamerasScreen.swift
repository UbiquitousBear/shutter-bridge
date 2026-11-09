#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && os(iOS)
import CameraTransport
import SwiftUI
import UIKit

/// The Cameras screen (backlog section 6): the connected cameras with a USB-C badge and the mode in the camera's
/// wording, the empty state, a clear message when ImageCaptureCore's access is off, and another with Try Again when
/// discovery couldn't start at all (so it isn't taken for "No Camera Connected"). Its toolbar opens Settings.
/// While a job exists, the same import strip as on Browse sits at the top and opens the Import screen.
///
/// Wi-Fi (wireless plan W16), from the models the app puts in the environment, each optional so a build without them is
/// the USB screen it was:
/// - `WirelessSetupModel`: an Add Wi-Fi Camera menu in the bar (Pair Over Bluetooth, hidden without Bluetooth, and Type an
///   Address), the two sheets, and a notice once a camera is added.
/// - `WiFiImportModel`: a strip with the connection's step, the stay's countdown and the notes (mobile data while joined,
///   the camera's Wi-Fi that may stay on after leaving), naming the camera.
/// - `ReminderModel`: the *nearby* badge on a camera the proximity scan reported lately, and the camera a reminder's
///   *Import Now* named, opened in Browse once it is listed (a Wi-Fi camera is joined as Browse opens it).
/// A Wi-Fi camera's row has a Wi-Fi badge and its route instead of a USB mode, and never a battery level or free space.
struct CamerasScreen: View {
    let model: CamerasModel
    var importer: ImportModel?
    var showSettings: @MainActor () -> Void = {}
    var showImport: @MainActor () -> Void = {}
    @Environment(\.openURL) private var openURL
    @Environment(WirelessSetupModel.self) private var setup: WirelessSetupModel?
    @Environment(WiFiImportModel.self) private var wifiStatus: WiFiImportModel?
    @Environment(ReminderModel.self) private var reminders: ReminderModel?

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
                if let setup {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        AddWiFiCameraMenu(setup: setup) {
                            Label(CamerasWording.addWiFiCamera, systemImage: "plus")
                        }
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
                    if let setup, let added = setup.addedNotice {
                        NoticeStrip(notice: added) {
                            if setup.addedNotice == added { setup.dismissAddedNotice() }
                        }
                    }
                    if let wifiStatus, wifiStatus.hasStatus(for: wifiStatus.camera) {
                        JoinStatusView(status: wifiStatus, cameraName: wifiCameraName(wifiStatus.camera))
                    }
                    if let importer, importer.hasJob {
                        ImportStatusStrip(importer: importer, action: showImport)
                    }
                }
            }
            .animation(.default, value: model.noticeStatus)
            .animation(.default, value: setup?.addedNotice)
            .animation(.default, value: wifiStatus?.activityLine)
            .animation(.default, value: wifiStatus?.notes)
            .animation(.default, value: importer?.hasJob)
            .onChange(of: model.noticeStatus) { _, notice in notice?.announcement.post() }
            .onChange(of: setup?.addedNotice) { _, notice in notice?.announcement.post() }
            .modifier(WirelessSetupSheets(setup: setup))
            // A reminder's Import Now (W18): open its camera once it is listed with its key.
            .onChange(of: reminders?.cameraToOpen, initial: true) { _, _ in openRequestedCamera() }
            .onChange(of: model.knownKeys) { _, _ in openRequestedCamera() }
    }

    /// The name of the Wi-Fi camera the connection status is about, when it is listed.
    private func wifiCameraName(_ id: CameraDescriptor.ID?) -> String? {
        guard let id, let camera = model.cameras.first(where: { $0.id == id }) else { return nil }
        return CamerasWording.displayName(for: camera)
    }

    /// Opens Browse on the camera a reminder's Import Now named, and takes the request once it is done; kept while the
    /// camera isn't listed with its key yet (a relaunch from the reminder lists the cameras after the screens are up).
    private func openRequestedCamera() {
        guard let reminders, let key = reminders.cameraToOpen, model.showCamera(withKey: key) else { return }
        _ = reminders.takeCameraToOpen()
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
            CamerasEmptyView(isLooking: model.isLooking, setup: setup)
        } else {
            List(model.cameras) { camera in
                NavigationLink(value: camera) {
                    if let reminders {
                        // The badge goes once the report is older than the window (`ReminderPolicy.nearbyWindow`), so
                        // the row is looked at again now and then, not only when a report comes.
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            CameraRow(camera: camera, isNearby: model.isNearby(camera) { reminders.isNearby($0) },
                                      statusLines: model.deviceStatusLines(for: camera))
                        }
                    } else {
                        CameraRow(camera: camera, statusLines: model.deviceStatusLines(for: camera))
                    }
                }
            }
        }
    }
}

/// A connected camera: its name, its mode (USB) or route (Wi-Fi), and badges for the link (USB-C or Wi-Fi) and, when the
/// proximity scan reported it lately, *nearby*. The device lines (battery, free space) come only from a link that reads
/// them, so a Wi-Fi row never has any, and an unread value is left out rather than shown as 0
/// (`CamerasModel.deviceStatusLines(for:)`). At the accessibility text sizes the row stacks, the decorative symbol goes
/// and the badges move under the mode line, so the long MTP mode line isn't wrapped a word per line (HIG Typography >
/// Dynamic Type). VoiceOver reads the row as one element, with a hint that says what opening it does.
struct CameraRow: View {
    let camera: CameraDescriptor
    var isNearby = false
    var statusLines: [String] = []
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
                Text(CamerasWording.detailLine(camera.mode))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(statusLines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !stacked {
                Spacer(minLength: 8)
            }
            let badges = stacked
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 6))
                : AnyLayout(VStackLayout(alignment: .trailing, spacing: 6))
            badges {
                switch camera.carrier {
                case .usb:
                    RowBadge(title: CamerasWording.usbBadge, systemImage: "cable.connector")
                case .wifi:
                    RowBadge(title: CamerasWording.wifiBadge, systemImage: "wifi")
                }
                if isNearby {
                    RowBadge(title: CamerasWording.nearbyBadge, systemImage: "dot.radiowaves.left.and.right")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(CamerasWording.rowHint(camera.mode))
    }
}

/// A badge on a camera's row. A fill, not a material: the row is solid, so there is nothing behind it to blur (HIG
/// Materials).
private struct RowBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

/// The Add Wi-Fi Camera menu: Pair Over Bluetooth (only when the app can pair) and Type an Address. In the Cameras bar,
/// and under the empty state.
struct AddWiFiCameraMenu<MenuLabel: View>: View {
    let setup: WirelessSetupModel
    @ViewBuilder var label: MenuLabel

    var body: some View {
        Menu {
            if setup.canPair {
                Button {
                    setup.showPairing()
                } label: {
                    Label(CamerasWording.pairOverBluetooth, systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            Button {
                setup.showTypedAddress()
            } label: {
                Label(CamerasWording.typeAddress, systemImage: "keyboard")
            }
        } label: {
            label
        }
        .accessibilityHint(setup.canPair ? CamerasWording.addWiFiCameraHint : CamerasWording.addWiFiCameraByAddressHint)
    }
}

/// No camera: the cable and the mode to choose, short, with *Which USB Mode?* for the modes in detail (HIG Writing;
/// `ContentUnavailableView`: a short title, a brief description, an action for more).
struct CamerasEmptyView: View {
    let isLooking: Bool
    /// When the app can set a Wi-Fi camera up: a line and the Add Wi-Fi Camera menu under the USB steps.
    var setup: WirelessSetupModel?
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
            if let setup {
                Text(CamerasWording.wifiEmptyHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                AddWiFiCameraMenu(setup: setup) {
                    Text(CamerasWording.addWiFiCamera)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
            }
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
