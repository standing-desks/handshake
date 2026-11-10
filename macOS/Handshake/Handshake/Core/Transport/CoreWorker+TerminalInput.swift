import Foundation
import HandshakeCore

extension CoreWorker {
    func writeTerminalInput(terminalID: UInt64, bytes: Data) async throws {
        try await writeTerminalBytes(terminalID: terminalID, bytes: bytes, userInput: true)
    }

    func writeWorkflowInput(terminalID: UInt64, bytes: Data, context: CoreWorkflowInputContext) async throws {
        while true {
            try Task.checkCancellation()
            let status = try withClient { client in
                bytes.withUnsafeBytes { input in
                    handshake_client_write_workflow_input(
                        client, terminalID, context.workflowID, context.agentID,
                        context.generation, context.modeRevision, input.bindMemory(to: UInt8.self).baseAddress,
                        input.count)
                }
            }
            if status == HANDSHAKE_STATUS_EMPTY {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                try checkTerminalStatus(status)
                return
            }
        }
    }

    func writeTerminalResponse(terminalID: UInt64, bytes: Data) async throws {
        try await writeTerminalBytes(terminalID: terminalID, bytes: bytes, userInput: false)
    }

    private func writeTerminalBytes(terminalID: UInt64, bytes: Data, userInput: Bool) async throws {
        while true {
            try Task.checkCancellation()
            let status = try withClient { client in
                bytes.withUnsafeBytes { input in
                    let write =
                        userInput ? handshake_client_write_terminal_input : handshake_client_write_terminal_response
                    return write(
                        client,
                        terminalID,
                        input.bindMemory(to: UInt8.self).baseAddress,
                        input.count
                    )
                }
            }
            if status == HANDSHAKE_STATUS_EMPTY {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                try checkTerminalStatus(status)
                return
            }
        }
    }

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) throws {
        let status = try withClient { client in
            handshake_client_resize_terminal(
                client,
                terminalID,
                size.rows,
                size.columns,
                size.pixelWidth,
                size.pixelHeight
            )
        }
        try checkTerminalStatus(status)
    }

    private func checkTerminalStatus(_ status: HandshakeStatus) throws {
        if status == HANDSHAKE_STATUS_TERMINAL_NOT_RUNNING { throw CoreFailure.terminalNotRunning }
        try check(status)
    }

}
