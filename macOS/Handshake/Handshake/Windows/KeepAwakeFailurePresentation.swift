import SwiftUI

/// Presents app-wide power failures once, in the key window, including the opening screen.
struct KeepAwakeFailurePresentation: ViewModifier {
    @Environment(KeepAwakeModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @State private var failure: String?
    weak var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.failure, initial: true) { _, _ in presentFailure() }
            .onChange(of: activeState) { _, _ in presentFailure() }
            .alert(
                "Keep Awake",
                isPresented: Binding(
                    get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
    }

    private func presentFailure() {
        guard window?.isKeyWindow == true, let message = model.failure else { return }
        failure = message
        model.failure = nil
    }
}
