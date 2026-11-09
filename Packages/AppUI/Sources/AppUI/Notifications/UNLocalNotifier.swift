#if canImport(UserNotifications) && os(iOS)
import Foundation
import UserNotifications

/// The live `LocalNotifier`, over `UNUserNotificationCenter`. No delegate is set, so iOS shows nothing while the app is
/// in front; the app posts only while it is away anyway. The centre is fetched in each call rather than kept, so the
/// notifier stays a plain `Sendable` value.
public struct UNLocalNotifier: LocalNotifier {
    public init() {}

    public func authorisation() async -> NotificationAuthorisation {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorised
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .denied
        }
    }

    /// Alerts and sounds: the pause notification is something to act on. No badge: the app keeps no count to show.
    public func requestAuthorisation() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func post(_ notification: AppNotification) async {
        let content = UNMutableNotificationContent()
        if !notification.title.isEmpty { content.title = notification.title }
        content.body = notification.body
        content.categoryIdentifier = notification.category.identifier
        content.sound = .default
        // No trigger: delivered now.
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    public func withdraw(_ notification: AppNotification) async {
        let centre = UNUserNotificationCenter.current()
        centre.removePendingNotificationRequests(withIdentifiers: [notification.identifier])
        centre.removeDeliveredNotifications(withIdentifiers: [notification.identifier])
    }

    public func registerCategories() async {
        let categories = AppNotificationCategory.all.map { category in
            UNNotificationCategory(
                identifier: category.identifier,
                actions: category.actions.map { action in
                    UNNotificationAction(identifier: action.identifier, title: action.title,
                                         options: action.opensApp ? [.foreground] : [])
                },
                intentIdentifiers: [],
                options: []
            )
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }
}
#endif
