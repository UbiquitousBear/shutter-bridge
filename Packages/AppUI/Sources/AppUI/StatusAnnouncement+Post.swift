#if canImport(SwiftUI) && canImport(Accessibility) && os(iOS)
import Accessibility
import SwiftUI

extension StatusAnnouncement {
    /// Posts this as a VoiceOver announcement (`AccessibilityNotification.Announcement`), with high priority for
    /// pauses and failures so VoiceOver doesn't drop it while it is speaking. The rules for what to say and when are
    /// in `StatusNotice` and `ImportWording.stateAnnouncement(from:to:statusLine:counts:)`.
    @MainActor func post() {
        var announcement = AttributedString(text)
        if priority == .high { announcement.accessibilitySpeechAnnouncementPriority = .high }
        AccessibilityNotification.Announcement(announcement).post()
    }
}
#endif
