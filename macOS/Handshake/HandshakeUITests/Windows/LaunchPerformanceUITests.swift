import XCTest

extension HandshakeUITests {
    @MainActor
    func testLaunchPerformance() throws {
        let app = try makeApp()
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
