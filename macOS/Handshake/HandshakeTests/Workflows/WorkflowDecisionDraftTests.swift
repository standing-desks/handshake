import Foundation
import Testing

@testable import Handshake

@Suite(.serialized)
@MainActor
struct WorkflowDecisionDraftTests {
    @Test func returningToEachAnswerTypeRestoresItsMappingsAndThresholds() throws {
        let (model, node) = makeDecision()
        model.setDecisionKind(node, kind: .score)
        let scoreOptions = try #require(model.definition.graph?.decisions[node]?.options)
        model.moveDecisionLevel(node, option: scoreOptions[2].id, to: 0)
        model.setDecisionKind(node, kind: .noul)
        model.setDecisionUncertain(node, enabled: true)
        model.swapDecisionAnswers(node)
        model.definition.graph?.decisions[node]?.trueThreshold = 8_750
        model.definition.graph?.decisions[node]?.falseThreshold = 1_250
        let binary = model.definition.graph?.edges
        model.setDecisionKind(node, kind: .choice)
        model.setDecisionKind(node, kind: .score)
        #expect(
            model.definition.graph?.decisions[node]?.options.map(\.id) == [
                scoreOptions[2].id, scoreOptions[0].id, scoreOptions[1].id,
            ])
        model.setDecisionKind(node, kind: .noul)
        #expect(model.definition.graph?.edges == binary)
        #expect(model.definition.graph?.decisions[node]?.trueThreshold == 8_750)
        #expect(model.definition.graph?.decisions[node]?.falseThreshold == 1_250)
        #expect(model.decisionIssues(node).isEmpty)
    }

    @Test func uncertaintyAndSingleCutoffEachRememberTheirValuesAndDestinations() throws {
        let (model, node) = makeDecision()
        model.setDecisionKind(node, kind: .noul)
        model.definition.graph?.decisions[node]?.trueThreshold = 6_350
        model.definition.graph?.decisions[node]?.falseThreshold = 6_350
        model.setDecisionUncertain(node, enabled: true)
        model.definition.graph?.decisions[node]?.trueThreshold = 8_525
        model.definition.graph?.decisions[node]?.falseThreshold = 1_575
        let bandEdges = model.definition.graph?.edges
        model.setDecisionUncertain(node, enabled: false)
        #expect(model.definition.graph?.decisions[node]?.trueThreshold == 6_350)
        #expect(model.definition.graph?.decisions[node]?.falseThreshold == 6_350)
        model.setDecisionUncertain(node, enabled: true)
        #expect(model.definition.graph?.decisions[node]?.trueThreshold == 8_525)
        #expect(model.definition.graph?.decisions[node]?.falseThreshold == 1_575)
        #expect(model.definition.graph?.edges == bandEdges)
    }

    @Test func restoringAFormReconcilesAddedAndDeletedWires() throws {
        let (model, node) = makeDecision()
        let edges = model.decisionEdges(node)
        model.setDecisionKind(node, kind: .score)
        let scoreOptions = try #require(model.definition.graph?.decisions[node]?.options)
        model.moveDecisionLevel(node, option: scoreOptions[2].id, to: 0)
        model.setDecisionKind(node, kind: .choice)
        model.removeGraphEdge(edges[0].id)
        model.connect(from: node, to: model.addGraphRole())
        let current = try #require(model.definition.graph?.edges)
        model.setDecisionKind(node, kind: .score)
        #expect(model.definition.graph?.edges.map(\.id) == current.map(\.id))
        #expect(model.definition.graph?.decisions[node]?.options.first?.id == scoreOptions[2].id)
        #expect(Set(model.definition.graph?.decisions[node]?.options.map(\.id) ?? []) == Set(scoreOptions.map(\.id)))
        #expect(model.decisionIssues(node).isEmpty)
    }

    @Test func answerTypeChangesHaveSpecificUndoAndRedoNames() throws {
        let (model, node) = makeDecision()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let previous = model.definition
        model.setDecisionKind(node, kind: .score)
        model.recordUndo(from: previous, using: manager)
        manager.endUndoGrouping()
        #expect(manager.undoActionName == "Change Answer Type")
        manager.undo()
        #expect(model.definition == previous)
        #expect(manager.redoActionName == "Change Answer Type")
        manager.redo()
        #expect(model.definition.graph?.decisions[node]?.kind == .score)
    }

    @Test func validationIdentifiesTheQuestionAndMissingAnswerAtTheirFields() throws {
        let (model, node) = makeDecision()
        let edges = model.decisionEdges(node)
        model.removeGraphEdge(edges[2].id)
        model.setDecisionKind(node, kind: .noul)
        model.definition.graph?.decisions[node]?.question = " "
        model.setDecisionUncertain(node, enabled: true)
        let issues = model.decisionValidation(node)
        #expect(issues.contains { $0.field == .question })
        #expect(issues.contains { $0.field == .answer("uncertain") })
        model.removeGraphEdge(edges[1].id)
        #expect(model.decisionValidation(node).isEmpty)
    }

    private func makeDecision() -> (WorkflowDesignerModel, String) {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let node = model.addGraphRole()
        model.setDecision(node, enabled: true)
        for _ in 0..<3 { model.connect(from: node, to: model.addGraphRole()) }
        return (model, node)
    }
}
