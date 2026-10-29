import Foundation
import Testing

@testable import Handshake

@Suite(.serialized)
@MainActor
struct WorkflowDecisionScoreTests {
    @Test func customCutoffsPersistAcrossModesAndAppearOnTheRightWires() throws {
        let (model, id) = makeScore()
        let options = try #require(model.definition.graph?.decisions[id]?.options)
        model.setDecisionOptionText(id, option: options[0].id, text: "Visual defect")
        model.setDecisionOptionText(id, option: options[1].id, text: "Workaround exists")
        model.setDecisionOptionText(id, option: options[2].id, text: "Work is blocked")
        model.setDecisionScoreThreshold(id, index: 0, value: 2_500)
        model.setDecisionScoreThreshold(id, index: 1, value: 14_000)
        let configured = try #require(model.definition.graph?.decisions[id])
        #expect(configured.effectiveScoreThresholds == [2_500, 14_000])
        let edges = model.decisionEdges(id)
        #expect(model.outputTitle(edges[0]) == "0 · Visual defect · score < 0.25")
        #expect(model.outputTitle(edges[1]) == "1 · Workaround exists · 0.25 ≤ score < 1.4")
        #expect(model.outputTitle(edges[2]) == "2 · Work is blocked · score ≥ 1.4")
        model.assignDecisionOutput(id, edge: edges[0].id, output: options[2].id)
        #expect(
            model.outputTitle(try #require(model.decisionEdges(id).first { $0.id == edges[0].id })).contains(
                "score ≥ 1.4"))
        model.setDecisionKind(id, kind: .noul)
        #expect(model.definition.graph?.decisions[id]?.scoreThresholds == nil)
        model.setDecisionKind(id, kind: .score)
        #expect(model.definition.graph?.decisions[id] == configured)
        let data = try JSONEncoder().encode(model.definition)
        #expect(try JSONDecoder().decode(CoreWorkflowType.Definition.self, from: data) == model.definition)
        #expect(model.decisionIssues(id).isEmpty)
    }

    @Test func rubricEditsAreIndependentOfConnectionsAndAlwaysClassification() throws {
        let (model, id) = makeScore()
        let original = try #require(model.definition.graph?.decisions[id]?.options)
        let first = try #require(model.decisionEdges(id).first)
        model.setDecisionScoreThreshold(id, index: 1, value: 17_500)
        model.definition.roles[1].name = "Renamed receiving agent"
        #expect(model.definition.graph?.decisions[id]?.options == original)
        model.setDecisionAlways(id, edge: first.id, enabled: true)
        #expect(model.definition.graph?.decisions[id]?.options == original)
        #expect(model.definition.graph?.decisions[id]?.scoreThresholds == [5_000, 17_500])
        #expect(model.decisionValidation(id).contains { $0.field == .answer(original[0].id) })
        model.setDecisionAlways(id, edge: first.id, enabled: false)
        #expect(model.decisionIssues(id).isEmpty)
        model.removeGraphEdge(first.id)
        #expect(model.definition.graph?.decisions[id]?.options == original)
        model.connect(from: id, to: model.addGraphRole())
        #expect(model.decisionIssues(id).isEmpty)
        model.addDecisionOption(id)
        #expect(model.definition.graph?.decisions[id]?.scoreThresholds == nil)
        #expect(model.definition.graph?.decisions[id]?.effectiveScoreThresholds == [5_000, 15_000, 25_000])
        let fourth = try #require(model.definition.graph?.decisions[id]?.options.last)
        model.removeDecisionOption(id, option: fourth.id)
        #expect(model.definition.graph?.decisions[id]?.options == original)
    }

    @Test func invalidThresholdsAreRepairableAndOldDefinitionsUseAutomaticCutoffs() throws {
        let (model, id) = makeScore()
        for invalid in [[5_000], [0, 15_000], [15_000, 5_000], [5_000, 5_000], [5_000, 20_000]] {
            model.definition.graph?.decisions[id]?.scoreThresholds = invalid
            #expect(model.decisionValidation(id).contains { $0.field == .thresholds })
        }
        model.definition.graph?.decisions[id]?.scoreThresholds = nil
        model.setDecisionScoreThreshold(id, index: 0, value: 15_000)
        #expect(model.definition.graph?.decisions[id]?.scoreThresholds == nil)
        model.setDecisionScoreThreshold(id, index: 1, value: 20_000)
        #expect(model.definition.graph?.decisions[id]?.scoreThresholds == nil)
        #expect(model.decisionIssues(id).isEmpty)
        let node = try #require(model.definition.graph?.decisions[id])
        var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        data.removeValue(forKey: "score_thresholds")
        let decoded = try JSONDecoder().decode(
            CoreWorkflowType.DecisionNode.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(decoded.effectiveScoreThresholds == [5_000, 15_000])
    }

    private func makeScore() -> (WorkflowDesignerModel, String) {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let id = model.addGraphRole()
        model.setDecision(id, enabled: true)
        for _ in 0..<3 { model.connect(from: id, to: model.addGraphRole()) }
        model.setDecisionKind(id, kind: .score)
        return (model, id)
    }
}
