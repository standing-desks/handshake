import Foundation

extension CoreClient {
    func startWorkflowRun(
        workflowID: UInt64, workflowType: CoreWorkflowType.Reference, roles: [CoreRoleLaunch], prompt: String = ""
    ) async throws {
        try await sendRunCommand(
            .startWorkflowRun(
                workflowID: workflowID, workflowType: workflowType, roles: roles, prompt: prompt,
                size: .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)))
    }

    func submitWorkflowTask(workflowID: UInt64, generation: UInt64, prompt: String) async throws {
        try await sendRunCommand(.submitWorkflowTask(workflowID: workflowID, generation: generation, prompt: prompt))
    }

    func chooseWorkflowResult(workflowID: UInt64, generation: UInt64, agentID: UInt64) async throws {
        try await sendRunCommand(
            .chooseWorkflowResult(workflowID: workflowID, generation: generation, agentID: agentID))
    }

    func retryDecision(workflowID: UInt64, generation: UInt64) async throws {
        try await sendRunCommand(.retryDecision(workflowID: workflowID, generation: generation))
    }

    func forceStopWorkflowAgents(workflowID: UInt64) async throws {
        try await sendRunCommand(.forceStopWorkflowAgents(workflowID: workflowID))
    }

    /// Fresh connected input can start coordination in the addressed conversation.
    func continueWorkflowIfNeeded(workflowID: UInt64, agentID: UInt64) async throws {
        try await prepareWorkflowInput(workflowID: workflowID, agentID: agentID)()
    }

    /// Capture the user's intent when input is queued, before waiting for earlier PTY writes.
    func prepareWorkflowInput(workflowID: UInt64, agentID: UInt64) -> TerminalInputPreparation {
        let observedRun = snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.run
        let change = workflowModeChanges[workflowID]
        let generation = change?.generation ?? observedRun?.generation
        let modeRevision = change?.modeRevision ?? observedRun?.modeRevision
        let terminalID = snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.agents.first(where: {
            $0.id == agentID
        })?.terminalID
        return { [weak self] in
            guard let self, let terminalID, let generation, let modeRevision else { return }
            workflowInputContexts[terminalID] = CoreWorkflowInputContext(
                workflowID: workflowID, agentID: agentID, generation: generation, modeRevision: modeRevision)
        }
    }

    func setWorkflowAgentsDisconnected(workflowID: UInt64, agentsDisconnected: Bool) async throws {
        guard workflowModeChanges[workflowID] == nil,
            let run = snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.run
        else { return }
        let expectedRevision =
            run.modeRevision + (run.agentsDisconnected == agentsDisconnected || run.modeRevision == .max ? 0 : 1)
        let completion = Task {
            try await sendRunCommand(
                .setWorkflowAgentsDisconnected(
                    workflowID: workflowID, generation: run.generation, modeRevision: run.modeRevision,
                    agentsDisconnected: agentsDisconnected))
            // A receipt precedes event delivery. Let the regular pump acknowledge this revision
            // so concurrent command completions are processed before the cursor advances.
            let deadline = ContinuousClock.now + .seconds(5)
            while true {
                try Task.checkCancellation()
                if ContinuousClock.now >= deadline {
                    throw CoreFailure.commandRejected(
                        code: "stateUpdateDelayed",
                        message:
                            "The connection change was accepted, but its status update is delayed. "
                            + "Terminal input remains available."
                    )
                }
                guard runState == .running, !isStopping, !isTerminating,
                    let updated = snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.run
                else { throw CoreFailure.notRunning }
                if updated.modeRevision >= expectedRevision { return }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        workflowModeChanges[workflowID] = .init(
            agentsDisconnected: agentsDisconnected, generation: run.generation, modeRevision: expectedRevision,
            completion: completion)
        defer { workflowModeChanges.removeValue(forKey: workflowID) }
        _ = try await completion.value
    }

    private func sendRunCommand(_ command: CoreCommand) async throws {
        let receipt = try await send(command)
        if let error = receipt.error {
            throw CoreFailure.commandRejected(code: error.code, message: error.message)
        }
    }
}
