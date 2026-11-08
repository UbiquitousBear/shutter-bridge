#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import PhotosBridge
import SwiftUI

/// The Settings screen (backlog section 6, *Settings, destination*; decision 9, 8 Nov): where imports go, Photos or
/// Files, app-wide, default Photos, saved as soon as it changes. The footer says that Files is used whatever the
/// setting when Photos access is off or restricted, and where the files go. Shown as a sheet from the Cameras
/// screen's toolbar.
struct SettingsScreen: View {
    @Bindable var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

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
                } header: {
                    Text(SettingsWording.destinationHeader)
                } footer: {
                    Text(SettingsWording.destinationFooter)
                }
            }
            .navigationTitle(SettingsWording.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(SettingsWording.done) { dismiss() }
                }
            }
        }
    }

    private static func symbol(for kind: DestinationKind) -> String {
        switch kind {
        case .photos: "photo.on.rectangle"
        case .filesFolder: "folder"
        }
    }
}
#endif
