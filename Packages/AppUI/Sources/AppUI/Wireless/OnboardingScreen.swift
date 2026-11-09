#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import SwiftUI
import UIKit

/// Pairing the camera over Bluetooth, once (backlog Iteration 3, section 6; wireless plan W16), drawn from
/// `OnboardingModel`: the steps first (`PairingExplainer`) with Start Pairing, then the wait for the two prompts with
/// Cancel, then paired (Done), not paired (Try Again, with the camera's Pairing screen named) or unavailable (what to do
/// next, with Open Settings when Bluetooth access is off). The buttons are the model's (`OnboardingModel.actions`), the
/// first prominent; nothing is greyed out, a step shows only what applies to it.
///
/// Shown as a sheet from the Cameras screen (`WirelessSetupSheets`). The close button and a swipe down both call `close`,
/// which cancels a check still waiting for the person (closing the Bluetooth link) and lists a camera that was paired.
/// VoiceOver hears each new step's title and detail.
struct OnboardingScreen: View {
    let model: OnboardingModel
    let close: @MainActor () -> Void
    @Environment(\.openURL) private var openURL
    /// The check started by Start Pairing or Try Again; cancelled if the sheet goes away first.
    @State private var check: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(OnboardingWording.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { close() }
                    }
                }
        }
        .onChange(of: model.step) { _, _ in
            StatusAnnouncement("\(model.title). \(model.detail)", priority: .high).post()
        }
        .onDisappear { check?.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .explain:
            List {
                Section {
                    Text(OnboardingWording.explainTitle)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                .listRowBackground(Color.clear)
                PairingExplainer(steps: model.steps, footer: model.detail)
            }
            .safeAreaBar(edge: .bottom) {
                actionButtons
                    .padding()
            }
        case .waiting:
            ContentUnavailableView {
                Label {
                    Text(model.title)
                } icon: {
                    ProgressView()
                        .controlSize(.large)
                }
            } description: {
                Text(model.detail)
            } actions: {
                actionButtons
            }
        case .paired:
            ContentUnavailableView {
                Label(model.title, systemImage: "checkmark.circle")
            } description: {
                Text(model.detail)
            } actions: {
                actionButtons
            }
        case .notPaired, .unavailable:
            ContentUnavailableView {
                Label(model.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(model.detail)
            } actions: {
                actionButtons
            }
        }
    }

    /// The step's buttons, in the model's order, the first prominent.
    private var actionButtons: some View {
        VStack(spacing: 12) {
            ForEach(Array(model.actions.enumerated()), id: \.offset) { index, action in
                actionButton(action, isPrimary: index == 0)
            }
        }
    }

    @ViewBuilder private func actionButton(_ action: OnboardingModel.Action, isPrimary: Bool) -> some View {
        let button = Button {
            perform(action)
        } label: {
            Text(action.title)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .accessibilityHint(Self.hint(for: action))
        if isPrimary {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private func perform(_ action: OnboardingModel.Action) {
        switch action {
        case .start, .tryAgain:
            let model = self.model
            check = Task { await model.start() }
        case .cancel:
            model.cancel()
        case .done:
            close()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }

    private static func hint(for action: OnboardingModel.Action) -> String {
        switch action {
        case .start: OnboardingWording.startHint
        case .cancel: OnboardingWording.cancelHint
        case .tryAgain: OnboardingWording.tryAgainHint
        case .done: OnboardingWording.doneHint
        case .openSettings: OnboardingWording.openSettingsHint
        }
    }
}
#endif
