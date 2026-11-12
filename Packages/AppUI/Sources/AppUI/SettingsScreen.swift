#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import PhotosBridge
import SwiftUI
import UIKit

/// The Settings screen (backlog section 6; Shamil, 11 Nov). There is no destination choice: the Import button offers
/// *Import to Photos* and *Stage* at each import. The Staging section says where staging goes (iCloud Drive › Shutter
/// Bridge › Staging, or On My iPhone › Shutter Bridge › Staging) and, when it is on this iPhone, why, with no Settings
/// button (the app's page in Settings has no iCloud switch). When Photos access is off or restricted, a row says
/// *Import to Photos* stages instead (HIG Settings: show what the app will actually do), with Open Settings after a
/// denial (HIG Privacy). Both are read when the screen appears and when the app comes back to the foreground. When
/// staged files haven't uploaded to iCloud Drive the section says so, the full iCloud quota first, or else how many are
/// waiting to upload (staging PR 7), read again when the screen appears. Shown as
/// a sheet from the Cameras screen's toolbar; nothing here needs saving, so the sheet closes with the system close
/// button, not Done (HIG Sheets).
///
/// When the app has a diagnostics exporter (I8), a row *Export Diagnostics…* makes the plain-text file of the app's own log and
/// opens the share sheet (`SharePresenter`) on it; the footer says what is in the file and that nothing is sent anywhere until
/// the person shares it. The model removes the file's folder once the sheet closes, and when Settings closes (`LiveApp`'s
/// sheet).
///
/// When the app has the proximity reminder (W18, placed by W16), a Reminders row pushes `ReminderSettingsView` inside this
/// sheet's navigation stack and says whether the reminder is on; the `ReminderModel` comes from the environment.
struct SettingsScreen: View {
    let model: SettingsModel
    @Environment(ReminderModel.self) private var reminders: ReminderModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let place = model.stagingPlace, let location = model.stagingLocation {
                        Label(location, systemImage: place == .iCloudDrive ? "icloud" : "iphone")
                            .accessibilityLabel(SettingsWording.stagingLocationAccessibility(place))
                    }
                    if let line = model.stagingFallbackLine {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let line = model.uploadProblemLine {
                        Label(line, systemImage: "exclamationmark.icloud")
                            .font(.subheadline)
                    } else if let line = model.uploadWaitingLine {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let line = model.forcedStagingLine {
                        Label(line, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                        if model.offersPhotosSettingsLink {
                            Button(ImportWording.openSettings) {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                    }
                } header: {
                    Text(SettingsWording.stagingHeader)
                } footer: {
                    Text(SettingsWording.stagingFooter)
                }
                if model.offersDiagnosticsExport {
                    Section {
                        Button {
                            Task { await model.exportDiagnostics() }
                        } label: {
                            HStack {
                                Text(DiagnosticsWording.rowTitle)
                                Spacer()
                                if model.exportState == .preparing { ProgressView() }
                            }
                        }
                        .disabled(model.isExporting)
                        .accessibilityValue(model.exportState == .preparing ? DiagnosticsWording.preparing : "")
                        .accessibilityHint(DiagnosticsWording.accessibilityHint)
                        if case let .failed(text) = model.exportState {
                            Label(text, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                        }
                    } footer: {
                        Text(DiagnosticsWording.footer)
                    }
                }
                if let reminders {
                    Section {
                        NavigationLink {
                            ReminderSettingsView(model: reminders)
                        } label: {
                            LabeledContent(ReminderWording.title,
                                           value: SettingsWording.remindersValue(on: reminders.remindsWhenNearby))
                        }
                        .accessibilityHint(SettingsWording.remindersHint)
                    }
                }
            }
            .navigationTitle(SettingsWording.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .task {
            await model.refresh()
            await model.refreshUploads()
        }
        // The file is ready: the share sheet, from UIKit's top-most controller, over this sheet. Its close, shared or not,
        // removes the file's folder.
        .onChange(of: model.exportState) { _, state in
            guard case let .ready(export) = state else { return }
            let model = self.model
            SharePresenter.present(fileAt: export.fileURL,
                                   onFinish: { model.exportFinished() },
                                   onFailure: { model.exportCouldNotBePresented() })
        }
        // The row only dims while the file is made, and a failure appears under it: say both (I17).
        .onChange(of: model.exportAnnouncement) { _, announcement in announcement?.post() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refresh() }
        }
    }
}
#endif
