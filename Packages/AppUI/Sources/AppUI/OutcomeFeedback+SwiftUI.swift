#if canImport(SwiftUI) && os(iOS)
import SwiftUI

extension OutcomeFeedback {
    /// The system haptic for this outcome.
    var sensoryFeedback: SensoryFeedback {
        switch self {
        case .success: .success
        case .warning: .warning
        case .error: .error
        case .selection: .selection
        }
    }
}
#endif
