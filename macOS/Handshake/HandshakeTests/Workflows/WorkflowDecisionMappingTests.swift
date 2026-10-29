import Testing

@testable import Handshake

@Suite(.serialized)
@MainActor
struct WorkflowDecisionMappingTests {
    @Test func legacyChoiceIDsDoNotDuplicateWiresAfterSwappingAndSelectingAlways() throws {
        let (model, node) = makeDecision(kind: .choice)
        let edges = model.decisionEdges(node)
        model.definition.graph?.decisions[node]?.options = edges.enumerated().map { index, edge in
            .init(id: edge.id, name: "Meaning \(index)", description: "Meaning \(index)")
        }
        for index in edges.indices { model.definition.graph?.edges[index].output = edges[index].id }
        model.assignDecisionOutput(node, edge: edges[0].id, output: edges[1].id)
        model.setDecisionAlways(node, edge: edges[1].id, enabled: true)
        let ordered = model.decisionEdges(node)
        #expect(ordered.count == edges.count)
        #expect(Set(ordered.map(\.id)).count == edges.count)
        model.setDecisionKind(node, kind: .score)
        model.setDecisionKind(node, kind: .choice)
        #expect(model.decisionEdges(node).count == edges.count)
        #expect(model.definition.graph?.decisions[node]?.options.count == 3)
        #expect(model.definition.graph?.decisions[node]?.options[0].name == "Meaning 0")
    }

    @Test func remappedScoreAssignmentsSurviveAnswerTypeChanges() {
        let (model, node) = makeDecision(kind: .score)
        let edges = model.decisionEdges(node)
        model.assignDecisionOutput(node, edge: edges[0].id, output: edges[1].id)
        let remapped = model.definition.graph?.edges
        model.setDecisionKind(node, kind: .noul)
        model.setDecisionKind(node, kind: .score)
        #expect(model.definition.graph?.edges == remapped)
        #expect(Set(model.decisionEdges(node).compactMap(\.output)).count == 3)
    }

    @Test func deletingARemappedScoreWireRemovesOnlyItsAssignedLevel() {
        let (model, node) = makeDecision(kind: .score)
        let edges = model.decisionEdges(node)
        model.assignDecisionOutput(node, edge: edges[0].id, output: edges[1].id)
        model.removeGraphEdge(edges[0].id)
        let options = model.definition.graph?.decisions[node]?.options ?? []
        #expect(options.count == 2)
        #expect(options.contains { $0.id == edges[0].id })
        #expect(!options.contains { $0.id == edges[1].id })
        #expect(model.decisionEdges(node).first { $0.id == edges[1].id }?.output == edges[0].id)
    }

    @Test func reclassifyingARemappedScoreWireKeepsOtherLevelsAndCreatesAUniqueReplacement() {
        let (model, node) = makeDecision(kind: .score)
        let edges = model.decisionEdges(node)
        model.assignDecisionOutput(node, edge: edges[0].id, output: edges[1].id)
        model.setDecisionAlways(node, edge: edges[0].id, enabled: true)
        #expect(model.definition.graph?.decisions[node]?.options.count == 2)
        #expect(model.definition.graph?.decisions[node]?.options.contains { $0.id == edges[0].id } == true)
        model.setDecisionAlways(node, edge: edges[0].id, enabled: false)
        let options = model.definition.graph?.decisions[node]?.options ?? []
        #expect(options.count == 3)
        #expect(Set(options.map(\.id)).count == 3)
        #expect(Set(model.decisionEdges(node).compactMap(\.output)).count == 3)
        #expect(model.decisionEdges(node).first { $0.id == edges[1].id }?.output == edges[0].id)
    }

    private func makeDecision(kind: CoreWorkflowType.DecisionKind) -> (WorkflowDesignerModel, String) {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let node = model.addGraphRole()
        model.setDecision(node, enabled: true)
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        model.setDecisionKind(node, kind: kind)
        return (model, node)
    }
}
