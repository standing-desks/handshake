import Foundation
import Testing

@testable import Handshake

@Suite(.serialized)
@MainActor
struct WorkflowDecisionAlwaysTests {
    @Test(arguments: CoreWorkflowType.DecisionKind.allCases)
    func alwaysTargetsRemainSeparateFromAnswersAcrossAllModes(kind: CoreWorkflowType.DecisionKind) throws {
        let (model, node) = makeDecision()
        model.setDecisionKind(node, kind: kind)
        let edges = model.decisionEdges(node)
        model.setAlwaysOutputs(node, enabled: true)
        for edge in edges.suffix(2) { model.setDecisionAlways(node, edge: edge.id, enabled: true) }
        #expect(model.decisionEdges(node).filter(\.always).count == 2)
        #expect(model.decisionIssues(node).isEmpty)
        for edge in model.decisionEdges(node).filter(\.always) { #expect(model.outputTitle(edge) == "Always") }
        if kind != .noul {
            #expect(model.definition.graph?.decisions[node]?.options.count == 2)
            #expect(
                model.definition.graph?.decisions[node]?.options.allSatisfy {
                    $0.id != edges[2].id && $0.id != edges[3].id
                } == true)
        }
        for other in CoreWorkflowType.DecisionKind.allCases {
            model.setDecisionKind(node, kind: other)
            #expect(model.decisionEdges(node).filter(\.always).count == 2)
            #expect(model.decisionEdges(node).filter(\.always).allSatisfy { $0.output == nil })
            #expect(model.decisionIssues(node).isEmpty)
        }
        model.setDecisionKind(node, kind: .noul)
        model.setDecisionUncertain(node, enabled: true)
        #expect(model.decisionValidation(node).contains { $0.field == .answer("uncertain") })
        #expect(model.decisionEdges(node).filter(\.always).count == 2)
        let data = try JSONEncoder().encode(model.definition)
        let decoded = try JSONDecoder().decode(CoreWorkflowType.Definition.self, from: data)
        #expect(decoded == model.definition)
        #expect(decoded.graph?.edges.filter(\.always).count == 2)
    }

    @Test func disablingAlwaysRetainsWiresAndRequiresAssignmentsForExtraChoiceConnections() {
        let (model, node) = makeDecision()
        let edges = model.decisionEdges(node)
        model.setDecisionAlways(node, edge: edges[2].id, enabled: true)
        model.setDecisionAlways(node, edge: edges[3].id, enabled: true)
        model.setAlwaysOutputs(node, enabled: false)
        #expect(!model.usesAlwaysOutputs(node))
        #expect(model.definition.graph?.decisions[node]?.options.count == 2)
        #expect(Set(model.decisionEdges(node).map(\.id)) == Set(edges.map(\.id)))
        #expect(!model.decisionIssues(node).isEmpty)
        model.addDecisionOption(node)
        model.addDecisionOption(node)
        #expect(model.decisionIssues(node).isEmpty)
        model.setDecisionAlways(node, edge: edges[2].id, enabled: true)
        model.setDecisionAlways(node, edge: edges[3].id, enabled: true)
        model.setDecisionKind(node, kind: .noul)
        model.setAlwaysOutputs(node, enabled: false)
        #expect(!model.decisionIssues(node).isEmpty)
        #expect(model.decisionEdges(node).count == 4)
    }

    @Test func assigningAnAlwaysTargetToYesSwapsItsPreviousDeliveryWithTheOldYesTarget() throws {
        let (model, node) = makeDecision()
        model.setDecisionKind(node, kind: .noul)
        let edges = model.decisionEdges(node)
        model.setDecisionAlways(node, edge: edges[2].id, enabled: true)
        model.setDecisionAlways(node, edge: edges[3].id, enabled: true)
        let previousYes = try #require(model.decisionEdges(node).first { $0.output == "yes" })
        model.assignDecisionOutput(node, edge: edges[2].id, output: "yes")
        #expect(model.decisionEdges(node).first { $0.id == previousYes.id }?.always == true)
        #expect(model.decisionEdges(node).first { $0.id == edges[2].id }?.output == "yes")
        #expect(model.decisionEdges(node).filter(\.always).count == 2)
        #expect(model.decisionIssues(node).isEmpty)
    }

    @Test func olderWorkflowEdgesDecodeAsConditionalAndAgentConversionClearsAlways() throws {
        let data = Data(#"{"id":"link","from":"a","to":"b","event":"done"}"#.utf8)
        #expect(try JSONDecoder().decode(CoreWorkflowType.Edge.self, from: data).always == false)
        let (model, node) = makeDecision()
        model.setDecisionAlways(node, edge: model.decisionEdges(node)[2].id, enabled: true)
        model.setDecision(node, enabled: false)
        #expect(model.definition.graph?.edges.allSatisfy { !$0.always && $0.output == nil } == true)
    }

    private func makeDecision() -> (WorkflowDesignerModel, String) {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let node = model.addGraphRole()
        model.setDecision(node, enabled: true)
        for _ in 0..<4 { model.connect(from: node, to: model.addGraphRole()) }
        return (model, node)
    }
}
