import AppKit
import Testing

@testable import Handshake

@MainActor
struct BrowserDialogsTests {
    @Test func retiringNativeSheetResolvesItsContinuationOnlyOnce() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        let dialogs = BrowserDialogs()
        var responses: [Bool] = []
        dialogs.confirm("Pending confirmation", origin: "localhost", window: window) { responses.append($0) }
        #expect(dialogs.isPresenting)
        dialogs.cancel()
        dialogs.cancel()
        #expect(!dialogs.isPresenting)
        #expect(responses == [false])
        window.orderOut(nil)
    }

    @Test func hiddenPagesResolveNativeDialogsWithoutPresenting() {
        let dialogs = BrowserDialogs()
        var alerts = 0
        var confirms: [Bool] = []
        var prompts: [String?] = []
        dialogs.alert("Hidden", origin: "localhost", window: nil) { alerts += 1 }
        dialogs.confirm("Hidden", origin: "localhost", window: nil) { confirms.append($0) }
        dialogs.prompt("Hidden", value: "default", origin: "localhost", window: nil) { prompts.append($0) }
        #expect(alerts == 1)
        #expect(confirms == [false])
        #expect(prompts.count == 1 && prompts[0] == nil)
    }
}
