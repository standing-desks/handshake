import Foundation
import Testing

@testable import Handshake

@Suite(.serialized)
@MainActor
struct WorkflowDecisionChoiceTests {
    @Test func creationModeEndsWhenItsChoiceIsUndoneRemovedOrReassigned() throws {
        let (model, node) = makeChoice()
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        let previous = try #require(model.decisionEdges(node).first { $0.output == nil })
        let beforeCreation = model.definition
        let option = try #require(model.addDecisionOption(node, edge: previous.id))
        let creation = WorkflowDecisionChoiceCreation(option: option, previous: previous)
        let created = model.definition
        #expect(creation.isValid(in: model.definition))
        model.setDecisionOptionText(node, option: option, text: "Still editing")
        #expect(creation.isValid(in: model.definition))
        model.definition = beforeCreation
        #expect(!creation.isValid(in: model.definition))
        model.definition = created
        model.removeDecisionOption(node, option: option)
        #expect(!creation.isValid(in: model.definition))
        model.definition = created
        model.assignDecisionOutput(node, edge: previous.id, output: nil)
        #expect(!creation.isValid(in: model.definition))
        model.definition = created
        model.setDecisionKind(node, kind: .score)
        #expect(!creation.isValid(in: model.definition))
    }

    @Test(arguments: ["unassigned", "choice", "always"])
    func cancellingNewChoicesRestoresThePreviousAssignment(_ assignment: String) throws {
        let (model, node) = makeChoice()
        for _ in 0..<4 { model.connect(from: node, to: model.addGraphRole()) }
        let edges = model.decisionEdges(node)
        model.setDecisionAlways(node, edge: edges[3].id, enabled: true)
        let target = assignment == "choice" ? edges[0].id : edges[2].id
        if assignment == "always" { model.setDecisionAlways(node, edge: target, enabled: true) }
        let previous = try #require(model.decisionEdges(node).first { $0.id == target })
        let original = model.definition
        let option = try #require(model.addDecisionOption(node, edge: target))
        model.setDecisionOptionText(node, option: option, text: "Changed my mind")
        model.cancelDecisionOptionCreation(option, restoring: previous)
        #expect(model.definition == original)
    }

    @Test func cancellingDoesNotTakeAPreviousChoiceBackFromAnotherConnection() throws {
        let (model, node) = makeChoice()
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        let edges = model.decisionEdges(node)
        let previous = edges[0]
        let option = try #require(model.addDecisionOption(node, edge: previous.id))
        model.assignDecisionOutput(node, edge: edges[2].id, output: previous.output)
        model.cancelDecisionOptionCreation(option, restoring: previous)
        #expect(model.decisionEdges(node).first { $0.id == previous.id }?.output == nil)
        #expect(model.decisionEdges(node).first { $0.id == edges[2].id }?.output == previous.output)
        #expect(model.definition.graph?.decisions[node]?.options.count == 2)
    }

    @Test func newEdgeChoicesHaveEditableDefaultTextWithoutASecondCreationStep() throws {
        let (model, node) = makeChoice()
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        let edge = try #require(model.decisionEdges(node).first { $0.output == nil })
        let option = try #require(model.addDecisionOption(node, edge: edge.id))
        #expect(model.definition.graph?.decisions[node]?.options.last?.name == "Option 3")
        #expect(model.decisionEdges(node).first { $0.id == edge.id }?.output == option)
        #expect(model.decisionIssues(node).isEmpty)
        model.setDecisionOptionText(node, option: option, text: "Needs review")
        #expect(model.outputTitle(try #require(model.decisionEdges(node).first { $0.id == edge.id })) == "Needs review")
        #expect(model.definition.graph?.decisions[node]?.options.last?.description == "Needs review")
        let saved = try JSONEncoder().encode(model.definition)
        #expect(try JSONDecoder().decode(CoreWorkflowType.Definition.self, from: saved) == model.definition)
    }

    @Test func creatingAChoiceOnAnEdgeAssignsThatEdgeInsteadOfTheFirstUnassignedOne() throws {
        let (model, node) = makeChoice()
        for _ in 0..<4 { model.connect(from: node, to: model.addGraphRole()) }
        let edges = model.decisionEdges(node)
        let original = try #require(model.definition.graph?.decisions[node]?.options)
        model.addDecisionOption(node, edge: edges[3].id, text: "  Needs review  ")
        let options = try #require(model.definition.graph?.decisions[node]?.options)
        let created = try #require(options.last)
        #expect(options.count == 3)
        #expect(Array(options.prefix(2)) == original)
        #expect(created.name == "Needs review" && created.description == "Needs review")
        #expect(model.decisionEdges(node).first { $0.id == edges[3].id }?.output == created.id)
        #expect(model.decisionEdges(node).first { $0.id == edges[2].id }?.output == nil)
        model.addDecisionOption(node, edge: edges[2].id, text: "Other work")
        #expect(model.decisionIssues(node).isEmpty)
        let saved = model.definition
        model.addDecisionOption(node, edge: "missing", text: "No destination")
        model.addDecisionOption(node, edge: edges[0].id, text: " \n ")
        #expect(model.definition == saved)
    }

    @Test func choicesMoveOntoUnassignedEdgesAndCanBeClearedWithoutChangingOtherEdges() throws {
        let (model, node) = makeChoice()
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        let edges = model.decisionEdges(node)
        let options = try #require(model.definition.graph?.decisions[node]?.options)
        model.assignDecisionOutput(node, edge: edges[2].id, output: options[0].id)
        #expect(model.decisionEdges(node).first { $0.id == edges[2].id }?.output == options[0].id)
        #expect(model.decisionEdges(node).first { $0.id == edges[0].id }?.output == nil)
        model.assignDecisionOutput(node, edge: edges[2].id, output: nil)
        #expect(model.decisionEdges(node).first { $0.id == edges[2].id }?.output == nil)
        #expect(model.decisionEdges(node).first { $0.id == edges[0].id }?.output == nil)
        #expect(model.decisionEdges(node).first { $0.id == edges[1].id } == edges[1])
        #expect(model.definition.graph?.decisions[node]?.options == options)
        #expect(model.decisionValidation(node).contains { $0.field == .answer(options[0].id) })
        model.setDecisionAlways(node, edge: edges[2].id, enabled: true)
        model.addDecisionOption(node, edge: edges[2].id, text: "New conditional choice")
        #expect(model.decisionEdges(node).first { $0.id == edges[2].id }?.always == false)
        #expect(model.definition.graph?.decisions[node]?.options.count == 3)
        #expect(model.definition.graph?.decisions[node]?.options.first == options.first)
    }

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
