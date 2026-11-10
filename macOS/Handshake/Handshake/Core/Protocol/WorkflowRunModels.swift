import Foundation

nonisolated struct CoreRoleLaunch: Codable, Equatable, Sendable {
    let role: String
    let harness: CoreHarness
    var model: String?
    var effort: String?
    /// Left out unless set, like the core's own records.
    var yolo: Bool?

    init(role: String, harness: CoreHarness, model: String? = nil, effort: String? = nil, yolo: Bool = false) {
        self.role = role
        self.harness = harness
        self.model = model
        self.effort = effort
        self.yolo = yolo ? true : nil
    }

    init(role: String, choice: HarnessChoice) {
        self.init(role: role, harness: choice.harness, model: choice.model, effort: choice.effort, yolo: choice.yolo)
    }
}

nonisolated struct CoreWorkflowRun: Decodable, Equatable, Sendable {
    let generation: UInt64
    let stage: String
    let status: Status
    let message: String?
    /// The first stage still has to report the task the user gave it.
    let needsTask: Bool
    let agents: [Agent]
    var outputs: [Output] = []
    var selectedResult: UInt64?
    var stageID: String?
    var workflowType: CoreWorkflowType?
    var workCompleted = false
    var agentsDisconnected = false
    var modeRevision: UInt64 = 0
    var decisionResults: [String: String] = [:]
    var decisionInputs: [String: String] = [:]
    var decisionOutputs: [String: String] = [:]
    var decisionErrors: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case workCompleted, generation, stage, status, message, needsTask, agents, workflowType, agentsDisconnected,
            modeRevision,
            outputs,
            selectedResult
        case decisionResults, decisionInputs, decisionOutputs, decisionErrors
        case stageID = "stageId"
    }

    enum Status: String, Decodable, Sendable {
        case running, idle, paused, completed, limitReached, cancelled, failed, interrupted
    }

    struct Output: Decodable, Equatable, Identifiable, Sendable {
        let agentId: UInt64
        let label: String
        let summary: String
        let elapsedMs: UInt64
        var id: UInt64 { agentId }
    }

    struct Agent: Decodable, Equatable, Identifiable, Sendable {
        let agentId: UInt64
        let active: Bool
        let done: Bool
        var harnessRunning: Bool?
        let reviewer: Bool
        let harness: CoreHarness
        let targets: [Target]
        var assignmentGeneration: UInt64?
        var role: String?
        var instance: Int?
        var status: AgentStatus?
        var id: UInt64 { agentId }

        /// Doing its stage's work now: an exited or failed harness is not working.
        var isWorking: Bool {
            guard active && !done else { return false }
            switch status {
            case nil, .waiting, .running: return true
            case .completed, .exited, .failed, .cancelled, .interrupted: return false
            }
        }
    }

    enum AgentStatus: String, Decodable, Sendable {
        case waiting, running, completed, exited, failed, cancelled, interrupted
    }

    struct Target: Decodable, Equatable, Identifiable, Sendable {
        let role: String
        let instance: Int
        let label: String
        var id: String { "\(role)-\(instance)" }
    }

}

extension CoreWorkflowRun {
    nonisolated init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        decisionResults = try values.decodeIfPresent([String: String].self, forKey: .decisionResults) ?? [:]
        decisionInputs = try values.decodeIfPresent([String: String].self, forKey: .decisionInputs) ?? [:]
        decisionOutputs = try values.decodeIfPresent([String: String].self, forKey: .decisionOutputs) ?? [:]
        decisionErrors = try values.decodeIfPresent([String: String].self, forKey: .decisionErrors) ?? [:]
        generation = try values.decode(UInt64.self, forKey: .generation)
        stage = try values.decode(String.self, forKey: .stage)
        status = try values.decode(Status.self, forKey: .status)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        needsTask = try values.decode(Bool.self, forKey: .needsTask)
        agents = try values.decode([Agent].self, forKey: .agents)
        outputs = try values.decodeIfPresent([Output].self, forKey: .outputs) ?? []
        selectedResult = try values.decodeIfPresent(UInt64.self, forKey: .selectedResult)
        stageID = try values.decodeIfPresent(String.self, forKey: .stageID)
        workflowType = try values.decodeIfPresent(CoreWorkflowType.self, forKey: .workflowType)
        workCompleted = try values.decodeIfPresent(Bool.self, forKey: .workCompleted) ?? false
        agentsDisconnected = try values.decodeIfPresent(Bool.self, forKey: .agentsDisconnected) ?? false
        modeRevision = try values.decodeIfPresent(UInt64.self, forKey: .modeRevision) ?? 0
    }
}

nonisolated struct CoreUserWorkflowVersion: Codable, Equatable, Sendable {
    let typeID: UInt64
    let version: UInt32
    private enum CodingKeys: String, CodingKey {
        case typeID = "type_id"
        case version
    }
}

/// Captured at the first queue boundary; it travels with binary terminal input.
nonisolated struct CoreWorkflowInputContext: Sendable {
    let workflowID: UInt64
    let agentID: UInt64
    let generation: UInt64
    let modeRevision: UInt64
}
