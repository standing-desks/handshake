import Foundation
import WebKit

/// Production tabs use the shared normal profile; desktop tests keep website data isolated.
enum BrowserConfiguration {
    #if DEBUG
        private static let testStore = WKWebsiteDataStore.nonPersistent()
    #endif

    static func make() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        #if DEBUG
            if ProcessInfo.processInfo.environment["HANDSHAKE_TEST_BROWSER_EPHEMERAL"] == "1" {
                configuration.websiteDataStore = testStore
            }
        #endif
        return configuration
    }
}
