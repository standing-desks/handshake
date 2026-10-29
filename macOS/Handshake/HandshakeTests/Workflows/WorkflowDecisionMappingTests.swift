import Testing

@testable import Handshake

@Suite(.serialized)
@MainActor
struct WorkflowDecisionMappingTests {
    @Test func clearingAnOutputPreservesAnswersAndOtherAlwaysWiresUntilItIsReassigned() throws {
        for kind in [CoreWorkflowType.DecisionKind.choice, .noul, .score] {
            let (model, node) = makeDecision(kind: kind)
            let edges = model.decisionEdges(node)
            if kind == .score, let output = edges[2].output { model.removeDecisionOption(node, option: output) }
            model.setDecisionAlways(node, edge: edges[2].id, enabled: true)
            #expect(model.decisionIssues(node).isEmpty)
            let options = model.definition.graph?.decisions[node]?.options
            let output = try #require(edges[0].output)
            let always = try #require(model.decisionEdges(node).first { $0.id == edges[2].id })
            model.assignDecisionOutput(node, edge: edges[0].id, output: nil)
            #expect(model.decisionEdges(node).first { $0.id == edges[0].id }?.output == nil)
            #expect(model.decisionEdges(node).first { $0.id == always.id } == always)
            #expect(model.definition.graph?.decisions[node]?.options == options)
            #expect(!model.decisionIssues(node).isEmpty)
            model.assignDecisionOutput(node, edge: edges[0].id, output: output)
            #expect(model.decisionIssues(node).isEmpty)
            model.assignDecisionOutput(node, edge: always.id, output: nil)
            #expect(model.decisionEdges(node).first { $0.id == always.id }?.always == false)
            #expect(model.decisionEdges(node).first { $0.id == always.id }?.output == nil)
            #expect(model.definition.graph?.decisions[node]?.options == options)
            #expect(!model.decisionIssues(node).isEmpty)
        }
    }

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

    @Test func remappedScoreAssignmentsSurviveAnswerTypeChanges() throws {
        let (model, node) = makeDecision(kind: .score)
        let edges = model.decisionEdges(node)
        let output = try #require(edges[1].output)
        model.assignDecisionOutput(node, edge: edges[0].id, output: output)
        let remapped = model.definition.graph?.edges
        model.setDecisionKind(node, kind: .noul)
        model.setDecisionKind(node, kind: .score)
        #expect(model.definition.graph?.edges == remapped)
        #expect(Set(model.decisionEdges(node).compactMap(\.output)).count == 3)
    }

    @Test func deletingARemappedScoreWirePreservesItsAuthoredLevel() throws {
        let (model, node) = makeDecision(kind: .score)
        let edges = model.decisionEdges(node)
        let output = try #require(edges[1].output)
        model.assignDecisionOutput(node, edge: edges[0].id, output: output)
        let options = model.definition.graph?.decisions[node]?.options
        model.removeGraphEdge(edges[0].id)
        #expect(model.definition.graph?.decisions[node]?.options == options)
        #expect(model.decisionValidation(node).contains { $0.field == .answer(output) })
        #expect(model.decisionEdges(node).first { $0.id == edges[1].id }?.output == edges[0].output)
    }

    @Test func reclassifyingARemappedScoreWireKeepsAllRubricLevels() throws {
        let (model, node) = makeDecision(kind: .score)
        let edges = model.decisionEdges(node)
        let output = try #require(edges[1].output)
        model.assignDecisionOutput(node, edge: edges[0].id, output: output)
        let options = model.definition.graph?.decisions[node]?.options
        model.setDecisionAlways(node, edge: edges[0].id, enabled: true)
        #expect(model.definition.graph?.decisions[node]?.options == options)
        #expect(!model.decisionIssues(node).isEmpty)
        model.setDecisionAlways(node, edge: edges[0].id, enabled: false)
        #expect(model.definition.graph?.decisions[node]?.options == options)
        #expect(Set(model.decisionEdges(node).compactMap(\.output)).count == 3)
        #expect(model.decisionEdges(node).first { $0.id == edges[0].id }?.output == output)
        #expect(model.decisionIssues(node).isEmpty)
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
