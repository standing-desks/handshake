import XCTest

extension HandshakeUITests {
    /// Accepts native tool consent for this isolated trial only, without saving a global preference.
    @MainActor
    func acceptLiveKiroConsent(in app: XCUIApplication, accepted: inout Set<URL>) {
        guard let directory = app.launchEnvironment["HANDSHAKE_DATA_DIRECTORY"] else {
            XCTFail("Missing isolated app data directory")
            return
        }
        let root = URL(filePath: directory)
            .appending(path: "transcripts")
        let previous = accepted
        var transcript: URL?
        let consent = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let files =
                    FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                    .allObjects.compactMap { $0 as? URL }.sorted { $0.path < $1.path } ?? []
                transcript = files.first {
                    $0.pathExtension == "bytes" && !previous.contains($0)
                        && (try? String(contentsOf: $0, encoding: .utf8).contains("No, exit")) == true
                }
                return transcript != nil
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [consent], timeout: 60), .completed)
        guard let transcript else { return }
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeText("\r")
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? String(contentsOf: transcript, encoding: .utf8)
                    .contains("ask a question or describe a task")) == true
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
        accepted.insert(transcript)
    }
}
