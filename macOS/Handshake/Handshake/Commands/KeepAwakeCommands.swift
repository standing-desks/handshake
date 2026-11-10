import SwiftUI

struct KeepAwakeCommands: Commands {
    let model: KeepAwakeModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle("Keep Awake", isOn: model.enabledBinding)
                .disabled(model.isUpdating)
        }
    }
}
