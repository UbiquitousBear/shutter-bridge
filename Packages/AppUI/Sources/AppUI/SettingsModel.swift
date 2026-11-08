import Foundation
import Observation
import PhotosBridge

/// The Settings screen's model (backlog section 6, *Settings, destination*; decision 9, 8 Nov): the destination,
/// Photos or Files, app-wide, default Photos, saved as soon as it changes. A job already running keeps its route;
/// the next import follows the setting (`ImportModel` reads the store at each start).
///
/// The screen binds a picker to `destination` and shows `SettingsWording.destinationFooter` under it. It is reached
/// from the Cameras screen's toolbar.
@MainActor
@Observable
public final class SettingsModel {
    /// Where imports go when Photos access allows it. Saved on every change.
    public var destination: DestinationKind {
        didSet {
            guard destination != oldValue else { return }
            store.save(DestinationSetting(preferred: destination))
        }
    }

    @ObservationIgnored private let store: any DestinationSettingStore

    public init(store: any DestinationSettingStore) {
        self.store = store
        destination = store.load().preferred
    }

    /// The choices, in the order the picker shows them.
    public static let choices: [DestinationKind] = [.photos, .filesFolder]

    /// The picker's label for a choice.
    public static func label(for kind: DestinationKind) -> String {
        SettingsWording.destinationLabel(kind)
    }
}
