import SwiftUI

extension View {
    /// Native actions beside the tabs share their height without glass prominence.
    func workspaceBarControl() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .controlSize(.small)
            .buttonSizing(.flexible)
            .font(.caption)
            .frame(height: WorkflowTabLayout.height)
    }
}
