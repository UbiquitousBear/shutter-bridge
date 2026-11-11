#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import PhotosBridge
import SwiftUI
import UIKit

/// The Settings screen (backlog section 6; Shamil, 11 Nov). There is no destination choice: the Import button offers
/// *Import to Photos* and *Stage* at each import. The Staging section says where staging goes (iCloud Drive › Shutter
/// Bridge › Staging, or On My iPhone › Shutter Bridge › Staging) and, when it is on this iPhone, why, with no Settings
/// button (the app's page in Settings has no iCloud switch). When Photos access is off or restricted, a row says
/// *Import to Photos* stages instead (HIG Settings: show what the app will actually do), with Open Settings after a
/// denial (HIG Privacy). Both are read when the screen appears and when the app comes back to the foreground. Shown as
/// a sheet from the Cameras screen's toolbar; nothing here needs saving, so the sheet closes with the system close
/// button, not Done (HIG Sheets).
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
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refresh() }
        }
    }
}
#endif
