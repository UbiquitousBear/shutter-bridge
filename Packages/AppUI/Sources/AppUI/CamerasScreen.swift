#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && os(iOS)
import CameraTransport
import SwiftUI
import UIKit

/// The Cameras screen (backlog section 6): the connected cameras with a USB-C badge and the mode in the camera's
/// wording, the empty state, and a clear message when ImageCaptureCore's access is off. Its toolbar opens Settings,
/// and the Import screen while a job is shown.
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
                ToolbarItem(placement: .topBarLeading) {
                    if let importer, importer.hasJob {
                        Button {
                            showImport()
                        } label: {
                            Label(CamerasWording.importButton, systemImage: "square.and.arrow.down")
                        }
                        .accessibilityValue(importer.statusLine ?? "")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings()
                    } label: {
                        Label(CamerasWording.settingsButton, systemImage: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let notice = model.noticeStatus {
                    NoticeStrip(notice: notice) {
                        if model.noticeStatus == notice { model.notice = nil }
                    }
                    .padding(.horizontal)
                }
            }
            .animation(.default, value: model.noticeStatus)
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
                Text(CamerasWording.displayName(for: camera))
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

/// A one-line message with a close button, for the top of a screen. A problem shows `exclamationmark.triangle` and
/// stays until closed; a confirmation closes itself after `StatusNotice.autoDismissDelay`, except while VoiceOver is
/// running. The close button's target is 44 × 44 pt (HIG Buttons); it is borderless, not glass, because the strip is
/// already a material surface.
struct NoticeStrip: View {
    let notice: StatusNotice
    let dismiss: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private struct TimerID: Hashable {
        var notice: StatusNotice
        var voiceOverEnabled: Bool
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.systemImage)
                .accessibilityHidden(true)
            Text(notice.text)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Label(BrowseWording.close, systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .font(.subheadline)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: TimerID(notice: notice, voiceOverEnabled: voiceOverEnabled)) {
            guard let delay = notice.dismissDelay(voiceOverRunning: voiceOverEnabled) else { return }
            // Cancelled when the notice changes or goes, or VoiceOver starts: then it isn't closed here.
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            dismiss()
        }
    }
}
#endif
