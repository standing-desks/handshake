import Foundation
import Testing

@testable import Handshake

struct BrowserAddressTests {
    @Test(arguments: [
        ("example.com/docs?q=hello#top", "https://example.com/docs?q=hello#top"),
        ("  example.com/a%20b?q=a%20b\n", "https://example.com/a%20b?q=a%20b"),
        ("localhost:3000/path", "http://localhost:3000/path"),
        ("127.0.0.1:8080", "http://127.0.0.1:8080"),
        ("[::1]:3000", "http://[::1]:3000"),
        ("https://localhost:3000", "https://localhost:3000"),
        ("HTTP://example.com", "HTTP://example.com"),
        ("about:blank", "about:blank"),
        ("intranet", "https://intranet"),
    ])
    func acceptsAddresses(_ pair: (String, String)) { #expect(BrowserAddress.parse(pair.0)?.absoluteString == pair.1) }

    @Test(arguments: [
        "", " \n ", "not a website", "https://", "file:///etc/hosts", "/tmp/page.html",
        "javascript:alert(1)", "javascript:123", "file:123", "mailto:123", "mailto:user@example.com",
        "https://user:pass@example.com",
        "https://example.com:0", "https://example.com:99999", "https://example.com:-1", "https://example.com:no",
        "ftp://example.com", "data:text/html,test", "https://exam\\ple.com", "example.com/a b",
    ])
    func rejectsInvalidAddresses(_ input: String) { #expect(BrowserAddress.parse(input) == nil) }

    @Test func externalProtocolsRequireAVisibleUserClick() {
        #expect(BrowserTab.opensExternally(scheme: "mailto", userClicked: true, visible: true))
        for scheme in ["", "file", "javascript", "about", "data", "blob", "webkit", "applewebdata"] {
            #expect(!BrowserTab.opensExternally(scheme: scheme, userClicked: true, visible: true))
        }
        #expect(!BrowserTab.opensExternally(scheme: "mailto", userClicked: false, visible: true))
        #expect(!BrowserTab.opensExternally(scheme: "mailto", userClicked: true, visible: false))
    }
}
