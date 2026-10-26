import Foundation
import Observation

/// App-wide presentation dependencies are created only after core has prepared the data root.
struct AppPresentation {
    let windows: FolderWindows
    let harnessModels: HarnessModelCatalog
    let zoom: AppZoom
    let settings: SettingsPopup
    let layouts: WorkflowLayouts

    init(dataDirectory: URL) {
        windows = FolderWindows(dataDirectory: dataDirectory)
        harnessModels = HarnessModelCatalog()
        zoom = AppZoom()
        settings = SettingsPopup(dataDirectory: dataDirectory)
        layouts = WorkflowLayouts(fileURL: dataDirectory.appending(path: "workflow-layouts.json"))
    }
}

@Observable
final class AppStartup {
    enum State {
        case waiting
        case preparing
        case ready(AppPresentation)
        case failed(String)
    }

    private(set) var state = State.waiting

    /// Multiple folder windows share this one bootstrap, including its failure result.
    func prepare(_ launch: AppPaths.Launch = AppPaths.launch) async {
        guard case .waiting = state else { return }
        state = .preparing
        do {
            let directory = try await CoreClient.prepareDataDirectory(launch)
            state = .ready(AppPresentation(dataDirectory: directory))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
