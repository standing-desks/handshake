import SwiftUI

/// Both node types use the same compact name and color controls.
struct WorkflowNodeIdentityFields: View {
    @Binding var role: CoreWorkflowType.Role

    var body: some View {
        HStack(spacing: 12) {
            TextField("Name", text: $role.name).textFieldStyle(.plain)
                .accessibilityIdentifier("graphAgentName")
            Menu {
                Picker("Color", selection: $role.color) {
                    Text("None").tag(nil as CoreWorkflowType.AgentColor?)
                    ForEach(CoreWorkflowType.AgentColor.allCases, id: \.self) { value in
                        Text(value.rawValue.capitalized).tag(Optional(value))
                    }
                }.pickerStyle(.inline)
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 14)).frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Node color: \(role.color?.rawValue.capitalized ?? "None")").accessibilityLabel("Node color")
            .accessibilityValue(role.color?.rawValue.capitalized ?? "None")
        }
    }
}
