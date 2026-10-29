import Foundation
import Testing

@testable import Handshake

@MainActor
struct WorkflowDecisionResultPresentationTests {
    @Test func probabilityOfYesIsUnambiguousEvenWhenTheNoRouteWins() {
        var node = CoreWorkflowType.DecisionNode()
        node.kind = .noul
        let result = presentation(#"{"type":"noul","probability":0.17}"#, node: node, output: "no")
        #expect(result.title == "No → Receiver")
        #expect(result.detail == "Probability of Yes: 17%")
    }

    @Test func scoreSummaryKeepsTheFractionAndNamesTheSelectedLevel() {
        var node = CoreWorkflowType.DecisionNode()
        node.kind = .score
        node.options = (0..<3).map { .init(id: "level-\($0)", name: "Level \($0)", description: "Level \($0)") }
        let result = presentation(#"{"type":"score","value":1.43}"#, node: node, output: "level-1")
        #expect(result.title == "Score 1.43 / 2 → Receiver")
        #expect(result.detail == "Level 1: Level 1 · 0.5 ≤ score < 1.5")
    }

    @Test func optionProbabilityIsPresentedWithoutCallingItConfidence() {
        var node = CoreWorkflowType.DecisionNode()
        node.options = [.init(id: "route-1", name: "Needs planning", description: "Needs planning")]
        let result = presentation(
            #"{"type":"choice","distribution":[{"option_id":"route-1","probability":0.83}]}"#,
            node: node, output: "route-1")
        #expect(result.title == "Needs planning → Receiver")
        #expect(result.detail == "Option probability: 83%")
    }

    @Test func missingOrUnsupportedReportsKeepTheKnownDestinationVisible() {
        for report in [nil, "{}", "not json"] as [String?] {
            let result = WorkflowDecisionResultPresentation.make(
                report: report, node: nil, output: "route-1", destination: "Receiver")
            #expect(result.title == "Routed to Receiver")
            #expect(result.detail == nil)
        }
    }

    private func presentation(
        _ answer: String, node: CoreWorkflowType.DecisionNode, output: String
    ) -> WorkflowDecisionResultPresentation {
        let report = """
            {"version":1,"result":{"kind":"turn","report":{"outcome":{"outcomes":[
                {"question_id":"route","status":"answered","answer":\(answer)}
            ]}}}}
            """
        return .make(
            report: report, node: node, output: output, destination: "Receiver", locale: Locale(identifier: "en_US"))
    }
}
