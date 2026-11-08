#if canImport(SwiftUI)
import SwiftUI

/// The app's first screen. For now a placeholder Cameras screen with the empty state, and nothing that pretends to
/// find a camera; Cameras, Browse and Import arrive with backlog section 6.
public struct RootView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            CamerasPlaceholder()
                .navigationTitle("Cameras")
        }
    }
}

struct CamerasPlaceholder: View {
    private let copy = CamerasEmptyState.standard

    var body: some View {
        ContentUnavailableView {
            Label(copy.title, systemImage: "cable.connector")
        } description: {
            VStack(spacing: 12) {
                Text(copy.connect)
                Text(copy.modeAdvice)
                Text(copy.remoteShootNote)
            }
        } actions: {
            Text(CamerasEmptyState.notYetLookingNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
