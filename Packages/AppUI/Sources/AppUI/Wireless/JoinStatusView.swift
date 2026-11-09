#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import SwiftUI

// The Wi-Fi connection's status on the screens (backlog Iteration 3, sections 1 and 8; wireless plan W15 and W16), drawn
// from `WiFiImportModel`: the step of the join or the stay, the wait for iOS's Local Network prompt, the note that the
// phone's internet uses mobile data while joined, and the note that the camera's Wi-Fi may stay on for a while after
// leaving. The Local Network explanation comes before the first connection, as a sheet over Browse (where connections
// begin) or in the Import screen's list. Unknown is not zero: nothing here shows a battery level or free space.

/// The connection's line and notes: a glass strip among the top strips (`StatusStrips`) on Cameras and Browse, or a list
/// row on the Import screen. A spinner while the session is busy getting somewhere (`WiFiImportModel.showsActivity`),
/// otherwise the Wi-Fi symbol; a countdown while the phone stays on the camera's network after an import; and a close
/// button once the only note left is the one after leaving.
struct JoinStatusView: View {
    enum Style {
        /// Glass, for `StatusStrips`.
        case strip
        /// Plain, for a list section.
        case row
    }

    let status: WiFiImportModel
    /// The camera's name, on the Cameras screen where several are listed (the status pill names the camera and the link).
    var cameraName: String?
    var style: Style = .strip

    var body: some View {
        switch style {
        case .strip:
            content
                .font(.subheadline)
                .padding(.leading, 14)
                .padding(.trailing, status.canDismissNotes ? 4 : 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: stripShape)
        case .row:
            content
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if status.showsActivity {
                    ProgressView()
                } else {
                    Image(systemName: "wifi")
                }
            }
            .accessibilityHidden(true)
            lines
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            if status.canDismissNotes {
                Button {
                    status.dismissNotes()
                } label: {
                    Label(WiFiWording.dismissNotes, systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityHint(WiFiWording.dismissNotesHint)
            }
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cameraName {
                Text(cameraName)
                    .fontWeight(.semibold)
            }
            if let line = status.activityLine {
                Text(line)
                    .modifier(StripLimit(applies: style == .strip))
            }
            let now = Date()
            if let end = status.stayCountdownEnd(now: now) {
                Text("\(WiFiWording.stayCountdownPrefix) \(Text(timerInterval: now ... end, countsDown: true))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ForEach(status.notes, id: \.self) { note in
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .modifier(StripLimit(applies: style == .strip))
            }
        }
    }
}

/// The strips' line limit on a strip, none in a list row.
private struct StripLimit: ViewModifier {
    let applies: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if applies {
            content.stripLineLimit()
        } else {
            content
        }
    }
}

/// Before the first connection over Wi-Fi: why iOS is about to ask for Local Network access, with Continue (which records
/// it, so it never comes again) and Not Now (which cancels the connection). Full, for the sheet; compact, for a list row.
struct LocalNetworkExplanationView: View {
    let status: WiFiImportModel
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 12) {
                Label(WiFiWording.localNetworkTitle, systemImage: "network")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(WiFiWording.localNetworkDetail)
                    .fixedSize(horizontal: false, vertical: true)
                // Side by side, or one above the other at the accessibility sizes so neither title is cut short (the
                // pattern of `CameraRow`).
                let buttons = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                buttons {
                    continueButton
                        .buttonStyle(.borderedProminent)
                    notNowButton
                        .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        } else {
            ContentUnavailableView {
                Label(WiFiWording.localNetworkTitle, systemImage: "network")
            } description: {
                Text(WiFiWording.localNetworkDetail)
            } actions: {
                continueButton
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                notNowButton
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        }
    }

    private var continueButton: some View {
        Button(WiFiWording.localNetworkContinue) { status.continueAfterExplaining() }
            .accessibilityHint(WiFiWording.localNetworkContinueHint)
    }

    private var notNowButton: some View {
        Button(WiFiWording.localNetworkNotNow) { status.declineExplaining() }
            .accessibilityHint(WiFiWording.localNetworkNotNowHint)
    }
}

/// Puts the Local Network explanation up as a sheet while a connection waits for it; a swipe down is Not Now
/// (`WiFiImportModel.showsLocalNetworkExplanation`). Does nothing without a status model (a USB camera, or a build with
/// no Wi-Fi).
private struct LocalNetworkExplanationSheet: ViewModifier {
    let status: WiFiImportModel?

    @ViewBuilder func body(content: Content) -> some View {
        if let status {
            content.modifier(Presenter(status: status))
        } else {
            content
        }
    }

    private struct Presenter: ViewModifier {
        @Bindable var status: WiFiImportModel

        func body(content: Content) -> some View {
            content.sheet(isPresented: $status.showsLocalNetworkExplanation) {
                LocalNetworkExplanationView(status: status)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

extension View {
    /// The Local Network explanation as a sheet over this view, while `status` has a connection waiting for it.
    func localNetworkExplanation(_ status: WiFiImportModel?) -> some View {
        modifier(LocalNetworkExplanationSheet(status: status))
    }
}

/// The Cameras screen's sheets for setting a Wi-Fi camera up (`WirelessSetupModel`): the pairing and the typed address.
/// Does nothing without a setup model (a build with no Wi-Fi).
struct WirelessSetupSheets: ViewModifier {
    let setup: WirelessSetupModel?

    @ViewBuilder func body(content: Content) -> some View {
        if let setup {
            content.modifier(Presenter(setup: setup))
        } else {
            content
        }
    }

    private struct Presenter: ViewModifier {
        @Bindable var setup: WirelessSetupModel

        func body(content: Content) -> some View {
            content.sheet(item: $setup.presentedSheet) { sheet in
                switch sheet {
                case .pairing:
                    if let onboarding = setup.onboarding {
                        OnboardingScreen(model: onboarding, close: { setup.close() })
                    }
                case .typedAddress:
                    if let typed = setup.typedAddress {
                        TypedAddressSheet(model: typed, close: { setup.close() })
                            .presentationDetents([.medium, .large])
                    }
                }
            }
        }
    }
}
#endif
