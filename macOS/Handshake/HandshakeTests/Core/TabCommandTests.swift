import Foundation
import Testing

@testable import Handshake

struct TabCommandTests {
    @Test func moveWorkflowSendsTheWorkflowAndItsNewSession() throws {
        let envelope = CommandEnvelope(requestID: 9, command: .moveWorkflow(workflowID: 4, sessionID: 2))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        #expect(command["type"] as? String == "moveWorkflow")
        #expect(command["workflowId"] as? UInt64 == 4)
        #expect(command["sessionId"] as? UInt64 == 2)
        #expect(command["name"] == nil)
    }

    @Test func renamingStillSendsItsName() throws {
        let envelope = CommandEnvelope(requestID: 3, command: .renameWorkflow(workflowID: 4, name: "API fix"))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        #expect(command["type"] as? String == "renameWorkflow")
        #expect(command["name"] as? String == "API fix")
        #expect(command["sessionId"] == nil)
    }
}
