import Foundation
import PhotosBridge

/// Where the app keeps the Import button's remembered choice (Shamil, 11 Nov: *Import to Photos* or *Stage*, the last
/// one used, app-wide, default Photos). It is the value the destination setting of 8 Nov (Photos or Files, chosen in
/// Settings) was stored as, under the same key, so what an earlier build stored still reads: Files reads as *Stage*.
/// PhotosBridge defines the value and the rule; persisting it is the app layer's. A protocol so the models are tested
/// on Linux with an in-memory store.
public protocol DestinationSettingStore: Sendable {
    /// The stored choice, or the default (Photos) when nothing, or something unreadable, is stored.
    func load() -> DestinationSetting
    func save(_ setting: DestinationSetting)
}

/// The setting in memory: for tests and previews.
public final class InMemoryDestinationSettingStore: DestinationSettingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var setting: DestinationSetting

    public init(_ setting: DestinationSetting = .default) {
        self.setting = setting
    }

    public func load() -> DestinationSetting { lock.withLock { setting } }
    public func save(_ setting: DestinationSetting) { lock.withLock { self.setting = setting } }
}

/// The choice in `UserDefaults`, as the value's JSON under one key. `DestinationSetting` decodes leniently, so a
/// value written by a later version reads as Photos rather than failing, and Files, written before 11 Nov, as
/// *Stage*. Foundation only, so it is tested on Linux against a suite of its own. (`UserDefaults` is thread-safe,
/// hence `@unchecked Sendable`.)
public final class UserDefaultsDestinationSettingStore: DestinationSettingStore, @unchecked Sendable {
    public static let key = "destinationSetting"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> DestinationSetting {
        guard let data = defaults.data(forKey: Self.key),
              let setting = try? JSONDecoder().decode(DestinationSetting.self, from: data) else { return .default }
        return setting
    }

    public func save(_ setting: DestinationSetting) {
        guard let data = try? JSONEncoder().encode(setting) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The Photos albums' `localIdentifier`s in `UserDefaults` (PhotosBridge's `AlbumIdentifierStore`; backlog section 5:
/// an album is found by its stored identifier, not its title). One dictionary under one key; a key's identifier is
/// removed when set to nil.
public final class UserDefaultsAlbumIdentifierStore: AlbumIdentifierStore, @unchecked Sendable {
    public static let key = "photosAlbumIdentifiers"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func albumIdentifier(forKey key: String) async -> String? {
        lock.withLock { stored()[key] }
    }

    public func setAlbumIdentifier(_ identifier: String?, forKey key: String) async {
        lock.withLock {
            var all = stored()
            all[key] = identifier
            defaults.set(all, forKey: Self.key)
        }
    }

    private func stored() -> [String: String] {
        (defaults.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
    }
}
