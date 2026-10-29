import Foundation
import Testing

@testable import Handshake

@Suite(.serialized)
@MainActor
struct WorkflowDecisionDesignerTests {
    @Test func decisionOptionsFollowConnectedAgentNames() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let node = model.addGraphRole(at: .init(x: 200, y: 200))
        let instructions = model.definition.roles[0].instructions
        let receivers = (0..<4).map { _ in model.addGraphRole() }
        model.setDecision(node, enabled: true)
        for receiver in receivers { model.connect(from: node, to: receiver) }
        let edges = try #require(model.definition.graph?.edges)
        let options = try #require(model.definition.graph?.decisions[node]?.options)
        #expect(edges.count == 4 && options.count == 4)
        #expect(Set(edges.map(\.id)) == Set(options.map(\.id)))
        #expect(edges.allSatisfy { $0.output == $0.id })
        for edge in edges {
            let option = try #require(options.first { $0.id == edge.id })
            #expect(option.name == model.nodeName(edge.to))
            #expect(option.description == model.nodeName(edge.to))
        }
        model.definition.graph?.decisions[node]?.minConfidence = 6_000
        model.definition.roles[1].name = "Renamed agent"
        #expect(model.outputTitle(edges[0]) == "Renamed agent")
        model.definition.graph?.decisions[node]?.minConfidence = nil
        model.removeGraphEdge(edges[3].id)
        #expect(model.definition.graph?.decisions[node]?.options.count == 3)
        model.removeGraphRole(receivers[2])
        #expect(model.definition.graph?.decisions[node]?.options.count == 2)
        let copy = try #require(model.duplicateGraphAgent(node))
        #expect(model.definition.graph?.decisions[copy]?.options.isEmpty == true)
        model.setDecision(node, enabled: false)
        #expect(model.definition.graph?.decisions[node] == nil)
        #expect(model.definition.graph?.edges.allSatisfy { $0.output == nil } == true)
        #expect(model.definition.roles.first { $0.id == node }?.instructions == instructions)
        #expect(model.definition.graph?.positions[node] == .init(x: 200, y: 200))
        let encoded = try JSONEncoder().encode(model.definition)
        #expect(try JSONDecoder().decode(CoreWorkflowType.Definition.self, from: encoded) == model.definition)
    }
    @Test func yesNoAssignmentsAndUncertaintyPreserveConnections() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let node = model.addGraphRole()
        model.setDecision(node, enabled: true)
        model.definition.graph?.decisions[node]?.question = "Is it ready?"
        let targets = (0..<4).map { _ in model.addGraphRole() }
        for target in targets { model.connect(from: node, to: target) }
        let original = try #require(model.definition.graph?.edges)
        model.setDecisionKind(node, kind: .noul)
        #expect(model.definition.graph?.edges.map(\.id) == original.map(\.id))
        #expect(model.definition.graph?.decisions[node]?.trueThreshold == 5_000)
        #expect(model.definition.graph?.decisions[node]?.falseThreshold == 5_000)
        #expect(!model.decisionIssues(node).isEmpty)
        model.removeGraphEdge(original[3].id)
        model.removeGraphEdge(original[2].id)
        #expect(model.decisionIssues(node).isEmpty)
        let yes = try #require(model.decisionEdges(node).first { $0.output == "yes" })
        model.swapDecisionAnswers(node)
        #expect(model.decisionEdges(node).first { $0.id == yes.id }?.output == "no")
        model.setDecisionUncertain(node, enabled: true)
        #expect(!model.decisionIssues(node).isEmpty)
        model.connect(from: node, to: targets[2])
        #expect(model.decisionEdges(node).first { $0.to == targets[2] }?.output == "uncertain")
        #expect(model.decisionIssues(node).isEmpty)
        model.setDecisionUncertain(node, enabled: false)
        #expect(model.decisionEdges(node).count == 3)
        #expect(!model.decisionIssues(node).isEmpty)
        model.setDecisionKind(node, kind: .choice)
        #expect(model.decisionEdges(node).count == 3)
        #expect(model.decisionIssues(node).isEmpty)
        #expect(model.definition.graph?.decisions[node]?.question == "Is it ready?")
    }

    @Test func scoreLevelsReorderWithoutRewiringOrLosingTheQuestion() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let node = model.addGraphRole()
        model.setDecision(node, enabled: true)
        model.setDecisionKind(node, kind: .score)
        model.definition.graph?.decisions[node]?.question = "How complex is the work?"
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        let edges = try #require(model.definition.graph?.edges)
        model.moveDecisionLevel(node, option: edges[2].id, to: 0)
        #expect(model.definition.graph?.edges == edges)
        #expect(model.definition.graph?.decisions[node]?.options.map(\.id) == [edges[2].id, edges[0].id, edges[1].id])
        #expect(model.outputTitle(edges[2]).hasPrefix("0 · "))
        #expect(model.outputTitle(edges[0]).hasPrefix("1 · "))
        #expect(model.decisionIssues(node).isEmpty)
        model.setDecisionKind(node, kind: .noul)
        model.setDecisionKind(node, kind: .score)
        #expect(model.definition.graph?.edges.map(\.id) == edges.map(\.id))
        #expect(model.definition.graph?.decisions[node]?.options.map(\.id) == [edges[2].id, edges[0].id, edges[1].id])
        #expect(model.definition.graph?.decisions[node]?.question == "How complex is the work?")
        let encoded = try JSONEncoder().encode(model.definition)
        #expect(try JSONDecoder().decode(CoreWorkflowType.Definition.self, from: encoded) == model.definition)
    }

    @Test func importedScoreRubricLabelsAgreeAcrossSettingsAndWiresAfterReordering() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let node = model.addGraphRole()
        model.setDecision(node, enabled: true)
        model.setDecisionKind(node, kind: .score)
        for _ in 0..<2 { model.connect(from: node, to: model.addGraphRole()) }
        model.definition.graph?.decisions[node]?.options = [
            .init(id: "low", name: "Small change", description: "One localized edit"),
            .init(id: "high", name: "Large change", description: "Cross-component work"),
        ]
        model.definition.graph?.edges[0].output = "low"
        model.definition.graph?.edges[1].output = "high"
        model.moveDecisionLevel(node, option: "high", to: 0)
        let edges = model.decisionEdges(node)
        let options = try #require(model.definition.graph?.decisions[node]?.options)
        for (index, option) in options.enumerated() {
            let edge = try #require(edges.first { $0.output == option.id })
            #expect(
                WorkflowDecisionLabels.scoreLevelName(option, edge: edge, definition: model.definition) == option.name)
            #expect(model.outputTitle(edge) == "\(index) · \(option.name)")
        }
    }

}
