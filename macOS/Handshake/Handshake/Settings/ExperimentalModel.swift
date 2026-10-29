import Foundation
import Observation

/// The core owns the feature catalog and settings-file edits; this model tracks presentation and conflicts.
@Observable
final class ExperimentalModel {
    private(set) var snapshot: ExperimentalSnapshot?
    private(set) var failure: String?
    private(set) var isSaving = false
    private(set) var needsApply = false
    @ObservationIgnored private var readGeneration = UUID()

    func load(client: CoreClient) async {
        guard !isSaving else { return }
        let generation = UUID()
        readGeneration = generation
        do {
            let current = try await client.experimental()
            guard readGeneration == generation, !isSaving else { return }
            snapshot = current
            failure = needsApply ? "A saved change still needs to be applied. Choose Apply Again." : nil
        } catch {
            guard readGeneration == generation, !isSaving else { return }
            snapshot = nil
            failure = error.localizedDescription
        }
    }

    func set(
        _ id: ExperimentalFeatureID, enabled: Bool, client: CoreClient,
        didSave: (FilePreview) async throws -> Void
    ) async {
        guard !isSaving, !needsApply, let version = snapshot?.file.version else { return }
        isSaving = true
        readGeneration = UUID()
        failure = nil
        defer { isSaving = false }
        do {
            let result = try await client.setExperimentalFeature(id, enabled: enabled, expectedVersion: version)
            guard result.status == .saved, let file = result.file else {
                if result.status == .conflict {
                    snapshot = try await client.experimental()
                    failure = "Settings changed elsewhere. The current values are shown; try your change again."
                } else {
                    failure = result.message ?? "The experimental feature could not be saved."
                }
                return
            }
            recordSaved(file, id: id, enabled: enabled)
            needsApply = true
            try await didSave(file)
            needsApply = false
            snapshot = try await client.experimental()
            failure = nil
        } catch {
            failure =
                needsApply
                ? "Saved, but couldn't apply the change to every folder. \(error.localizedDescription)"
                : error.localizedDescription
        }
    }

    private func recordSaved(_ file: FilePreview, id: ExperimentalFeatureID, enabled: Bool) {
        // A confirmed receipt remains current even when a subsequent read fails.
        guard let previous = snapshot else { return }
        snapshot = ExperimentalSnapshot(
            features: previous.features.map { feature in
                ExperimentalFeatureState(
                    id: feature.id, title: feature.title, description: feature.description,
                    enabled: feature.id == id ? enabled : feature.enabled)
            }, file: file)
    }

    func configurationApplied(client: CoreClient) async {
        needsApply = false
        await load(client: client)
    }

    func applyAgain(client: CoreClient, apply: (FilePreview) async throws -> Void) async {
        guard !isSaving else { return }
        isSaving = true
        readGeneration = UUID()
        defer { isSaving = false }
        do {
            let current = try await client.experimental()
            snapshot = current
            try await apply(current.file)
            needsApply = false
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}
