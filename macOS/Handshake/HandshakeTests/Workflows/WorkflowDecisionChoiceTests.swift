import Foundation
import Testing

@testable import Handshake

@Suite(.serialized)
@MainActor
struct WorkflowDecisionChoiceTests {
    @Test func extraWiresNeedExplicitOptionsOrAlwaysAssignments() throws {
        let (model, node) = makeChoice()
        for _ in 0..<4 { model.connect(from: node, to: model.addGraphRole()) }
        let edges = model.decisionEdges(node)
        #expect(model.definition.graph?.decisions[node]?.options.count == 2)
        #expect(edges.filter { $0.output == nil }.count == 2)
        #expect(model.decisionValidation(node).contains { $0.field == .connections })
        model.addDecisionOption(node)
        model.addDecisionOption(node)
        #expect(model.decisionIssues(node).isEmpty)
        let option = try #require(model.definition.graph?.decisions[node]?.options.first)
        model.setDecisionOptionText(node, option: option.id, text: "Small change")
        model.removeDecisionOption(node, option: option.id)
        #expect(model.decisionEdges(node).count == 4)
        #expect(model.decisionEdges(node).first { $0.id == edges[0].id }?.output == nil)
        model.setDecisionAlways(node, edge: edges[0].id, enabled: true)
        #expect(model.decisionIssues(node).isEmpty)
    }

    @Test func selectingAnOptionOnAnAlwaysWireSwapsTheAssignmentWithoutLosingText() throws {
        let (model, node) = makeChoice()
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        let edges = model.decisionEdges(node)
        let option = try #require(model.definition.graph?.decisions[node]?.options.first)
        model.setDecisionOptionText(node, option: option.id, text: "Escalate to a specialist")
        model.setDecisionAlways(node, edge: edges[2].id, enabled: true)
        model.assignDecisionOutput(node, edge: edges[2].id, output: option.id)
        #expect(model.decisionEdges(node).first { $0.id == edges[0].id }?.always == true)
        #expect(model.decisionEdges(node).first { $0.id == edges[2].id }?.output == option.id)
        #expect(
            model.outputTitle(try #require(model.decisionEdges(node).first { $0.id == edges[2].id }))
                == "Escalate to a specialist")
        #expect(model.decisionIssues(node).isEmpty)
        model.setDecisionKind(node, kind: .score)
        model.setDecisionKind(node, kind: .choice)
        #expect(model.definition.graph?.decisions[node]?.options.first?.name == "Escalate to a specialist")
        #expect(model.decisionEdges(node).first { $0.id == edges[2].id }?.output == option.id)
        let encoded = try JSONEncoder().encode(model.definition)
        #expect(try JSONDecoder().decode(CoreWorkflowType.Definition.self, from: encoded) == model.definition)
    }

    @Test func unassignedOptionsRemainEditableAcrossModeChangesAndAlwaysClassification() throws {
        let (model, node) = makeChoice()
        let first = try #require(model.definition.graph?.decisions[node]?.options.first)
        model.setDecisionOptionText(node, option: first.id, text: "Needs investigation")
        model.addDecisionOption(node)
        let authored = model.definition.graph?.decisions[node]?.options
        model.setDecisionKind(node, kind: .noul)
        model.setDecisionKind(node, kind: .choice)
        #expect(model.definition.graph?.decisions[node]?.options == authored)
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        let assigned = try #require(model.decisionEdges(node).first { $0.output == first.id })
        model.setDecisionAlways(node, edge: assigned.id, enabled: true)
        #expect(model.definition.graph?.decisions[node]?.options == authored)
        #expect(model.decisionValidation(node).contains { $0.field == .answer(first.id) })
        model.setDecisionAlways(node, edge: assigned.id, enabled: false)
        #expect(model.decisionIssues(node).isEmpty)
        model.setDecisionOptionText(node, option: first.id, text: "")
        #expect(
            model.decisionValidation(node).contains { $0.field == .answer(first.id) && $0.message.contains("text") })
    }

    private func makeChoice() -> (WorkflowDesignerModel, String) {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let node = model.addGraphRole()
        model.setDecision(node, enabled: true)
        return (model, node)
    }
}
