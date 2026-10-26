import Foundation
import Observation

/// The core owns the flag catalog and settings-file edits; this model tracks presentation and conflicts.
@Observable
final class FeatureFlagsModel {
    private(set) var snapshot: FeatureFlagSnapshot?
    private(set) var failure: String?
    private(set) var isSaving = false
    private(set) var needsApply = false
    @ObservationIgnored private var readGeneration = UUID()

    func load(client: CoreClient) async {
        guard !isSaving else { return }
        let generation = UUID()
        readGeneration = generation
        do {
            let current = try await client.featureFlags()
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
        _ id: FeatureFlagID, enabled: Bool, client: CoreClient,
        didSave: (FilePreview) async throws -> Void
    ) async {
        guard !isSaving, !needsApply, let version = snapshot?.file.version else { return }
        isSaving = true
        readGeneration = UUID()
        failure = nil
        defer { isSaving = false }
        do {
            let result = try await client.setFeatureFlag(id, enabled: enabled, expectedVersion: version)
            guard result.status == .saved, let file = result.file else {
                if result.status == .conflict {
                    snapshot = try await client.featureFlags()
                    failure = "Settings changed elsewhere. The current values are shown; try your change again."
                } else {
                    failure = result.message ?? "The feature flag could not be saved."
                }
                return
            }
            recordSaved(file, id: id, enabled: enabled)
            needsApply = true
            try await didSave(file)
            needsApply = false
            snapshot = try await client.featureFlags()
            failure = nil
        } catch {
            failure =
                needsApply
                ? "Saved, but couldn't apply the change to every folder. \(error.localizedDescription)"
                : error.localizedDescription
        }
    }

    private func recordSaved(_ file: FilePreview, id: FeatureFlagID, enabled: Bool) {
        // A confirmed receipt remains current even when a subsequent read fails.
        guard let previous = snapshot else { return }
        snapshot = FeatureFlagSnapshot(
            flags: previous.flags.map { flag in
                FeatureFlagState(
                    id: flag.id, title: flag.title, description: flag.description,
                    enabled: flag.id == id ? enabled : flag.enabled)
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
            let current = try await client.featureFlags()
            snapshot = current
            try await apply(current.file)
            needsApply = false
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}
