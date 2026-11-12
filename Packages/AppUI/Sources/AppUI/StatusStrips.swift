#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import SwiftUI

// The strips at the top of Cameras and Browse: a message, the Wi-Fi connection's step, and (Browse) Copy or Share as
// JPEG in progress. (The running import is the tab bar's bottom accessory, `LiveApp`.) They sit in a `safeAreaBar(edge: .top)`, so they take part in the scroll edge effect like the glass
// bar above them, and are drawn as Liquid Glass in one `GlassEffectContainer` rather than as material cards (HIG
// Materials > Liquid Glass). At the accessibility text sizes each is held to a few lines, so together they never
// fill the screen (HIG Dynamic Type), and in compact height (an iPhone in landscape) to one line with tighter
// spacing (HIG Layout); VoiceOver still reads the whole text. A problem notice keeps enough lines to be read in full,
// as it stays until closed and says what to do next (`StripLayout`).

/// The strips' shape: a rounded rectangle rather than a capsule, as their text can wrap.
var stripShape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

/// The most lines a strip's text takes, from the text size and the height class (`StripLayout`).
private struct StripLineLimit: ViewModifier {
    var isProblem = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content.lineLimit(StripLayout.lineLimit(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                                                isCompactHeight: verticalSizeClass == .compact,
                                                isProblem: isProblem))
    }
}

extension View {
    /// Holds a strip's text to `StripLayout.lineLimit(isAccessibilitySize:isCompactHeight:isProblem:)`.
    func stripLineLimit(isProblem: Bool = false) -> some View { modifier(StripLineLimit(isProblem: isProblem)) }
}

/// Stacks the strips under the navigation bar, as glass that can blend when they meet; closer together in compact
/// height.
struct StatusStrips<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let spacing = CGFloat(StripLayout.spacing(isCompactHeight: verticalSizeClass == .compact))
        GlassEffectContainer(spacing: spacing) {
            VStack(spacing: spacing) {
                content
            }
        }
        .padding(.horizontal)
    }
}

/// A message with a close button. A problem shows `exclamationmark.triangle` and stays until closed; a confirmation
/// closes itself after `StatusNotice.autoDismissDelay`, except while VoiceOver is running. The close button's target
/// is 44 × 44 pt (HIG Buttons); it is borderless, not glass, because the strip is glass already.
struct NoticeStrip: View {
    let notice: StatusNotice
    let dismiss: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private struct TimerID: Hashable {
        var notice: StatusNotice
        var voiceOverEnabled: Bool
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.systemImage)
                .accessibilityHidden(true)
            Text(notice.text)
                .stripLineLimit(isProblem: notice.tone == .problem)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Label(BrowseWording.close, systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .font(.subheadline)
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: stripShape)
        .task(id: TimerID(notice: notice, voiceOverEnabled: voiceOverEnabled)) {
            guard let delay = notice.dismissDelay(voiceOverRunning: voiceOverEnabled) else { return }
            // Cancelled when the notice changes or goes, or VoiceOver starts: then it isn't closed here.
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            dismiss()
        }
    }
}
#endif
