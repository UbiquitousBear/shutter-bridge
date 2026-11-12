#if canImport(AppIntents)
import AppIntents
import Catalogue
import Foundation

// The camera both intents take (I16; backlog section 5, D7 (a)). Compiled only by CI's Xcode job: the picker's rows
// come from `AppModel.intentCameras()` and their wording from `NewPhotosWording`, both tested on Linux.

/// A camera, as Shortcuts and Siri offer it: its name only, with when it was last connected as the second line, so two
/// cameras with one name can be told apart. Identified by its catalogue key, which is a hash where it comes from a
/// serial (`CameraKey`); the serial itself is never stored or shown.
public struct CameraEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Camera" }
    public static var defaultQuery: CameraEntityQuery { CameraEntityQuery() }

    /// The camera's catalogue key (`CameraKey.rawValue`).
    public let id: String
    public let name: String
    /// The picker's second line (`NewPhotosWording.lastConnected`), as it read when the camera was listed.
    public let detail: String

    public init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }

    init(_ camera: IntentCamera, now: Date = Date()) {
        self.init(id: camera.id, name: camera.name,
                  detail: NewPhotosWording.lastConnected(camera.lastConnected, now: now))
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    /// The camera's key, as `AppModel` takes it.
    var key: CameraKey { CameraKey(rawValue: id) }

    /// The cameras the picker lists, once the app's catalogue is open; none when it can't be opened.
    @MainActor
    static func listed() async -> [CameraEntity] {
        guard let model = await IntentHost.model() else { return [] }
        let now = Date()
        return await model.intentCameras().map { CameraEntity($0, now: now) }
    }
}

/// Finds cameras for the intents: those the catalogue knows, and a connected camera it doesn't know yet.
public struct CameraEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [CameraEntity.ID]) async throws -> [CameraEntity] {
        let listed = await CameraEntity.listed()
        return identifiers.compactMap { id in listed.first { $0.id == id } }
    }

    public func suggestedEntities() async throws -> [CameraEntity] {
        await CameraEntity.listed()
    }

    /// With one camera there is nothing to choose: Siri doesn't ask which.
    public func defaultResult() async -> CameraEntity? {
        let listed = await CameraEntity.listed()
        return listed.count == 1 ? listed.first : nil
    }
}
#endif
