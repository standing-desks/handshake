import SwiftUI

/// Keeps editor buffers mounted while the tab strip selects files and workflows.
struct FileTabsSurface: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(FileTabsModel.self) private var fileTabs
    let folder: String
    let failure: String?
    let isPresented: Bool
    var allowsAutomaticFocus = true
    let reportFailure: (String) -> Void

    var body: some View {
        ZStack {
            ForEach(fileTabs.editors) { editor in
                let shown = isPresented && editor.id == fileTabs.selectedID
                FileViewer(
                    path: editor.path, folder: editor.folder, failure: failure, isVisible: shown,
                    allowsAutomaticFocus: allowsAutomaticFocus,
                    openFile: { url in
                        if let request = editor.memoryRequest {
                            Task {
                                do {
                                    try await fileTabs.openMemoryLink(url, request: request, client: coreClient)
                                } catch { reportFailure(error.localizedDescription) }
                            }
                        } else {
                            fileTabs.open(path: url.path, folder: folder, navigationURL: url)
                        }
                    }
                )
                .environment(editor)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
                .disabled(!shown)
            }
        }
    }
}
