import Catalogue
import Foundation
import Observation

/// Settings › *Import When Connected* (backlog section 14): a switch for each camera body the catalogue knows by name
/// (D11, `AutoImportRule.choices(among:)`), off by default. A switch writes `CameraRecord.autoImport` on every one-body key
/// of its name and on no key shared by bodies, through `updateCamera(_:_:)`, one actor call per key, so a Wi-Fi
/// connection saving the same row meanwhile loses nothing. Read when the screen appears and when the app comes back to
/// the front, never in `SettingsModel.refresh()`, which the app awaits at each activation.
@MainActor
@Observable
public final class AutoImportSettings {
    public private(set) var choices: [AutoImportChoice] = []
    /// The last switch change wasn't saved; cleared by the next one that is.
    public private(set) var saveFailed = false

    @ObservationIgnored private let catalogue: any CatalogueStore
    @ObservationIgnored private let log: any BenchLog

    public init(catalogue: any CatalogueStore, log: any BenchLog = SilentBenchLog()) {
        self.catalogue = catalogue
        self.log = log
    }

    /// Reads the cameras again. A catalogue that can't be read leaves the rows as they were, and is logged.
    public func load() async {
        do {
            let read = AutoImportRule.choices(among: try await catalogue.cameras())
            if read != choices { choices = read }
        } catch {
            log.note("settings: auto-import: the catalogue couldn't be read (\(type(of: error)))")
        }
    }

    /// Turns the switch of the camera named `name` on or off: every one-body key of that name, from a fresh read, then
    /// the rows read back, so the switch shows what is stored.
    public func set(_ on: Bool, for name: String) async {
        do {
            let keys = AutoImportRule.keys(named: name, among: try await catalogue.cameras())
            for key in keys {
                try await catalogue.updateCamera(key) { $0.autoImport = on }
            }
            saveFailed = false
            log.note("settings: auto-import turned \(on ? "on" : "off") for a camera (\(keys.count) key(s))")
        } catch {
            saveFailed = true
            log.note("settings: auto-import wasn't saved: \(type(of: error))")
        }
        await load()
    }

    /// For `ForEach($model.choiceBindings)` (the `ReminderModel.cameraChoices` pattern): a changed switch shows its new
    /// value at once and is written in a task.
    public var choiceBindings: [AutoImportChoice] {
        get { choices }
        set {
            for choice in newValue {
                guard let index = choices.firstIndex(where: { $0.id == choice.id }),
                      choices[index].isOn != choice.isOn else { continue }
                choices[index].isOn = choice.isOn
                let name = choice.name
                let on = choice.isOn
                Task { [weak self] in await self?.set(on, for: name) }
            }
        }
    }

    /// More than one camera listed: MSC can't follow one, so the footer adds the MSC line.
    public var listsSeveralCameras: Bool { choices.count > 1 }
}
