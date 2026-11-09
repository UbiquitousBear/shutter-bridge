#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import SwiftUI

/// Typing the camera's address, for a camera on the same Wi-Fi network as the phone (backlog Iteration 3, section 5: "a
/// typed address is the escape hatch, always offered"), drawn from `TypedAddressModel`: what to type and where to find
/// it, the field, and under it what is wrong with the text and what to type instead (no complaint for an empty field).
/// Cancel and Add Camera in the bar (HIG Sheets: a sheet that collects input has both); Add Camera, and Return on the
/// keyboard, add a usable address only. What to type is the section's footer, which VoiceOver reads after the field, so
/// the field has no hint repeating it. The camera is listed on the Cameras screen, and the join happens when it is
/// opened. The address is never logged.
struct TypedAddressSheet: View {
    @Bindable var model: TypedAddressModel
    let close: @MainActor () -> Void
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(TypedAddressWording.explanation)
                }
                Section {
                    TextField(TypedAddressWording.fieldLabel, text: $model.text,
                              prompt: Text(TypedAddressWording.fieldPrompt))
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($fieldIsFocused)
                        .onSubmit { add() }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                    }
                } header: {
                    Text(TypedAddressWording.fieldLabel)
                } footer: {
                    Text(TypedAddressWording.fieldHint)
                }
            }
            .navigationTitle(TypedAddressWording.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TypedAddressWording.cancel, role: .cancel) { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(TypedAddressWording.connect) { add() }
                        .disabled(!model.canAdd)
                        .accessibilityHint(TypedAddressWording.connectHint)
                }
            }
            .animation(.default, value: model.message)
        }
        .onAppear { fieldIsFocused = true }
    }

    private func add() {
        let model = self.model
        Task { await model.add() }
    }
}
#endif
