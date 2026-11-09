#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import SwiftUI

/// What pairing asks of the person, before anything starts (backlog Iteration 3, section 6; `OnboardingWording`): the
/// camera's menu path to its Pairing screen, its two Bluetooth settings (*Bluetooth Function* and *Bluetooth Rmt Ctrl*),
/// and the two prompts that follow, iOS's Bluetooth pairing request and then the camera's confirmation. Numbered steps in
/// a list section, each read by VoiceOver as "Step 1 of 3. …"; the footer says iOS may also ask for Bluetooth access.
struct PairingExplainer: View {
    let steps: [String]
    var footer: String?

    var body: some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Label {
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    // "1.circle.fill" to "50.circle.fill" are SF Symbols; there are three steps.
                    Image(systemName: "\(index + 1).circle.fill")
                        .foregroundStyle(.tint)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(OnboardingWording.stepLabel(index + 1, of: steps.count, step))
            }
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}
#endif
