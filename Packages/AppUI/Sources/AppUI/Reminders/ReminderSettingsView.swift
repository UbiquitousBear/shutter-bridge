#if canImport(SwiftUI)
import SwiftUI

/// The reminder's settings (Iteration 4, section 12; W18): a switch for the reminder, the quiet hours and a choice per
/// camera. System controls only (`Toggle`, `DatePicker`, `Form`), so they take Liquid Glass and Dynamic Type as they come.
/// Nothing here is bound by a `Binding(get:set:)`: `ReminderModel` offers the properties a `@Bindable` model needs
/// (`remindsWhenNearby`, `quietStart`, `quietEnd`, `cameraChoices`), so the view holds no logic.
///
/// Pushed from Settings, or shown inside its navigation stack (W16 places it); it makes no stack of its own. The
/// quiet hours and the camera choices show only while the reminder is on. The footer says what the scan can't do
/// (`ProximityWording`), and a line says so when iOS won't deliver notifications.
public struct ReminderSettingsView: View {
    @Bindable var model: ReminderModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: ReminderModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                Toggle(ReminderWording.toggle, isOn: $model.remindsWhenNearby)
                if model.notificationsAreOff {
                    Label(ReminderWording.notificationsOff, systemImage: "bell.slash")
                        .font(.subheadline)
                }
            } footer: {
                Text(ReminderWording.footer)
            }

            if model.remindsWhenNearby {
                Section {
                    DatePicker(ReminderWording.quietFrom, selection: $model.quietStart, displayedComponents: .hourAndMinute)
                    DatePicker(ReminderWording.quietTo, selection: $model.quietEnd, displayedComponents: .hourAndMinute)
                } header: {
                    Text(ReminderWording.quietHoursHeader)
                } footer: {
                    Text(ReminderWording.quietSummary(model.settings.quietHours))
                }

                if !model.cameraChoices.isEmpty {
                    Section {
                        ForEach($model.cameraChoices) { $choice in
                            Toggle(choice.name, isOn: $choice.isReminded)
                        }
                    } header: {
                        Text(ReminderWording.camerasHeader)
                    } footer: {
                        Text(ReminderWording.camerasFooter)
                    }
                }
            }
        }
        .navigationTitle(ReminderWording.title)
        .task { await model.refreshAuthorisation() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshAuthorisation() }
        }
    }
}
#endif
