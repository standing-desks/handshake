import Foundation
import XCTest

/// Runs the bundled CLI inside a real app terminal, including its inherited authority.
@MainActor
final class BrowserCLIProbe {
    private let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try """
        #!/bin/sh
        printf ready > browser-ready
        while :; do
            for request in browser-command-*.request; do
                [ -f "$request" ] || continue
                /bin/sh "$request"
                /bin/rm -f "$request"
            done
            /bin/sleep 0.02
        done
        """.write(to: directory.appending(path: "browser-driver.sh"), atomically: true, encoding: .utf8)
    }

    func start(_ arguments: [String]) throws -> URL {
        let name = "browser-command-\(UUID())"
        let result = directory.appending(path: name + ".json")
        let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(
            separator: " ")
        try """
        "$HANDSHAKE_CLI" browser \(quoted) > '\(name).json' 2>&1
        printf done > '\(name).json.done'
        """.write(to: directory.appending(path: name + ".request"), atomically: true, encoding: .utf8)
        return result
    }

    func finish(_ file: URL) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(35)
        let done = URL(filePath: file.path + ".done")
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "Browser CLI exceeded its deadline")
        let data = try Data(contentsOf: file)
        do {
            let decoded = try JSONSerialization.jsonObject(with: data)
            return try XCTUnwrap(decoded as? [String: Any])
        } catch {
            XCTFail("CLI response: \(String(data: data, encoding: .utf8) ?? "Invalid UTF-8")")
            throw error
        }
    }

    func run(_ arguments: [String], succeeds: Bool = true) async throws -> [String: Any] {
        let result = try await finish(start(arguments))
        XCTAssertEqual(result["ok"] as? Bool, succeeds, String(describing: result["error"]))
        return result
    }

    static func snapshot(_ result: [String: Any]) throws -> [String: Any] {
        let text = try XCTUnwrap(result["content"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
