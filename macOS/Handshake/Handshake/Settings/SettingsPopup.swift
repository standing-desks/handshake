import AppKit
import OSLog
import Observation

private let settingsLogger = Logger(subsystem: "com.twineproject.Twine", category: "settings")

/// One app-wide editing buffer, presented as a sheet in the folder window that opened it.
@Observable
final class SettingsPopup {
    let experimental = ExperimentalModel()
    let coreClient: CoreClient
    private(set) var editor: FileEditorModel?
    private(set) var failure: String?
    private(set) var presentedWindowID: UUID?
    @ObservationIgnored private weak var source: FolderWindowSession?
    var isPresented: Bool { presentedWindowID != nil }

    init(dataDirectory: URL) {
        coreClient = CoreClient(transport: CoreWorker(dataDirectory: dataDirectory))
    }

    func show(in session: FolderWindowSession) {
        if isPresented {
            (source?.window?.attachedSheet ?? source?.window)?.makeKeyAndOrderFront(nil)
            return
        }
        source = session
        presentedWindowID = session.id
    }

    func load() async {
        failure = nil
        do {
            let file = try await coreClient.configFile()
            try Task.checkCancellation()
            guard isPresented else { return }
            let editor = FileEditorModel(
                path: file.path, folder: URL(filePath: file.path).deletingLastPathComponent().path,
                isConfigFile: true)
            editor.receive(file)
            self.editor = editor
            await experimental.load(client: coreClient)
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
            settingsLogger.error("Settings file could not be opened: \(error.localizedDescription, privacy: .public)")
        }
    }

    func close() {
        guard confirmDiscard() else { return }
        presentedWindowID = nil
        editor = nil
        failure = nil
        source = nil
    }

    func setExperimentalFeature(_ id: ExperimentalFeatureID, enabled: Bool, windows: FolderWindows) async {
        guard editor?.isDirty != true, editor?.isSaving != true else { return }
        await experimental.set(id, enabled: enabled, client: coreClient) { file in
            self.editor?.receive(file)
            try await windows.reloadConfig()
        }
        if let file = experimental.snapshot?.file { editor?.receive(file) }
    }

    func configurationSaved(windows: FolderWindows) async throws {
        try await windows.reloadConfig()
        await experimental.configurationApplied(client: coreClient)
        editor?.receive(experimental.snapshot?.file)
    }

    func retryExperimental(windows: FolderWindows) async {
        if experimental.needsApply {
            await experimental.applyAgain(client: coreClient) { file in
                self.editor?.receive(file)
                try await windows.reloadConfig()
            }
        } else {
            await experimental.load(client: coreClient)
            if let file = experimental.snapshot?.file { editor?.receive(file) }
        }
    }

    func confirmDiscard() -> Bool { editor?.confirmDiscard() ?? true }

}
