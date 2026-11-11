#if canImport(UIKit) && os(iOS)
import UIKit

/// Presents the system share sheet for one file (*Share as JPEG…*, and Settings' *Export Diagnostics…*). The sheet is
/// presented from UIKit's top-most view controller rather than wrapped in a SwiftUI sheet, which leaves an empty sheet
/// behind when an activity (Messages, Mail) presents its own screen. `onFinish` runs once the sheet and any activity it started have closed,
/// whether something was shared or not; that is when the file's temporary folder is removed. `onFailure` runs instead
/// when the sheet can't be shown: no window, or UIKit refused the presentation. Exactly one of the two runs.
@MainActor
enum SharePresenter {
    static func present(
        fileAt url: URL,
        onFinish: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        attempt(url, onFinish: onFinish, onFailure: onFailure, waitingForTransition: true)
    }

    private static func attempt(
        _ url: URL,
        onFinish: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable () -> Void,
        waitingForTransition: Bool
    ) {
        guard let presenter = topViewController(), let view = presenter.view else {
            onFailure()
            return
        }
        // A JPEG can be ready while a transition is still running (a pair JPG over MSC, within the context menu's
        // dismissal), and UIKit refuses a presentation then. Wait for it to end, once, and look again.
        if waitingForTransition, let coordinator = presenter.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in
                Task { @MainActor in
                    attempt(url, onFinish: onFinish, onFailure: onFailure, waitingForTransition: false)
                }
            }
            return
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinish() }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
        // UIKit sets `presentedViewController` at once when it accepts a presentation. When it refuses (mid-transition,
        // already presenting) it only logs, and the completion handler never runs.
        guard presenter.presentedViewController === controller else {
            controller.completionWithItemsHandler = nil
            onFailure()
            return
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
#endif
