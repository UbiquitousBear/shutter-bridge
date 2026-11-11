#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import PhotosBridge
import SwiftUI
import UIKit

/// The Settings screen (backlog section 6, *Settings, destination*; decision 9, 8 Nov): where imports go, Photos or
/// Files, app-wide, default Photos, saved as soon as it changes. When Photos access is off or restricted, a row under
/// the choice says the next import goes to Files whatever the setting (HIG Settings: show what the app will actually
/// do), with Open Settings after a denial (HIG Privacy); the access is read when the screen appears and when the app
/// comes back to the foreground. The footer says where files go in Files. Shown as a sheet from the Cameras screen's
/// toolbar; the choice is saved at once, so the sheet closes with the system close button, not Done (HIG Sheets).
///
/// When the app has the proximity reminder (W18, placed by W16), a Reminders row pushes `ReminderSettingsView` inside this
/// sheet's navigation stack and says whether the reminder is on; the `ReminderModel` comes from the environment.
struct SettingsScreen: View {
    @Bindable var model: SettingsModel
    @Environment(ReminderModel.self) private var reminders: ReminderModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(SettingsWording.destinationHeader, selection: $model.destination) {
                        ForEach(SettingsModel.choices, id: \.self) { kind in
                            Label(SettingsModel.label(for: kind), systemImage: Self.symbol(for: kind))
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if let line = model.forcedFilesLine {
                        Label(line, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                        if model.offersPhotosSettingsLink {
                            Button(ImportWording.openSettings) {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                    }
                } header: {
                    Text(SettingsWording.destinationHeader)
                } footer: {
                    Text(SettingsWording.destinationFooter)
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
        .task { await model.refreshPhotosAccess() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshPhotosAccess() }
        }
    }

    private static func symbol(for kind: DestinationKind) -> String {
        switch kind {
        case .photos: "photo.on.rectangle"
        case .staging: "folder"
        }
    }
}
#endif
