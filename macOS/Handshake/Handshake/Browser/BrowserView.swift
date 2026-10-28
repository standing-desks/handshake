import SwiftUI
import WebKit

struct BrowserTabsSurface: View {
    @Environment(BrowserTabsModel.self) private var browsers
    var isPresented: Bool
    var allowsAutomaticFocus: Bool

    var body: some View {
        ForEach(browsers.tabs) { tab in
            let visible = isPresented && browsers.selectedID == tab.id
            BrowserView(tab: tab, isVisible: visible, allowsAutomaticFocus: allowsAutomaticFocus)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
        }
    }
}

struct BrowserView: View {
    @Bindable var tab: BrowserTab
    let isVisible: Bool
    let allowsAutomaticFocus: Bool
    @State private var draft = ""
    @State private var validation: String?
    @State private var textSelection: TextSelection?
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Back", systemImage: "chevron.left") { tab.back() }
                    .disabled(!tab.canGoBack).accessibilityIdentifier("browserBack")
                Button("Forward", systemImage: "chevron.right") { tab.forward() }
                    .disabled(!tab.canGoForward).accessibilityIdentifier("browserForward")
                Button(tab.isLoading ? "Stop" : "Reload", systemImage: tab.isLoading ? "xmark" : "arrow.clockwise") {
                    if tab.isLoading { tab.stop() } else { tab.reload() }
                }
                .disabled(!tab.hasNavigated).accessibilityIdentifier("browserReload")
                TextField("Website address", text: $draft, selection: $textSelection)
                    .textFieldStyle(.roundedBorder)
                    .focused($editingAddress)
                    .onSubmit(submit)
                    .accessibilityIdentifier("browserAddress")
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
            .padding(10)
            if let message = validation ?? tab.failure {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
                    .accessibilityIdentifier("browserFailure")
            }
            Divider()
            ZStack(alignment: .top) {
                BrowserWebView(
                    tab: tab, isVisible: isVisible && tab.hasNavigated,
                    allowsKeyboardFocus: allowsAutomaticFocus && !editingAddress && !tab.hasNativeSheet
                )
                .accessibilityHidden(tab.hasNativeSheet)
                if !tab.hasNavigated {
                    ContentUnavailableView(
                        "New Browser Tab", systemImage: "globe",
                        description: Text("Enter a website address above to start browsing."))
                }
                if tab.isLoading {
                    ProgressView(value: tab.progress).progressViewStyle(.linear).controlSize(.mini)
                        .accessibilityIdentifier("browserProgress")
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: tab.address, initial: true) {
            if !editingAddress {
                draft = tab.address
                validation = nil
            }
        }
        .onChange(of: editingAddress) {
            if !editingAddress {
                draft = tab.address
            }
        }
        .onChange(of: tab.locationRequest) { focusAddress() }
        .onChange(of: isVisible, initial: true) {
            tab.isVisible = isVisible
            if !isVisible { editingAddress = false }
        }
        .task(id: isVisible) {
            await Task.yield()
            guard !Task.isCancelled, isVisible, !tab.hasNavigated else { return }
            focusAddress()
        }
        .onDisappear { tab.isVisible = false }
    }

    private func focusAddress() {
        guard isVisible, allowsAutomaticFocus else { return }
        draft = tab.address
        validation = nil
        editingAddress = true
        textSelection = TextSelection(range: draft.startIndex..<draft.endIndex)
    }

    private func submit() {
        guard let url = BrowserAddress.parse(draft) else {
            validation = BrowserAddress.invalidMessage
            editingAddress = true
            return
        }
        validation = nil
        editingAddress = false
        tab.load(url)
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let tab: BrowserTab
    let isVisible: Bool
    let allowsKeyboardFocus: Bool
    @Environment(\.appZoom) private var zoom

    func makeNSView(context: Context) -> RetainedContentHost<WKWebView> {
        RetainedContentHost(content: tab.webView, responder: tab.webView)
    }

    func updateNSView(_ host: RetainedContentHost<WKWebView>, context: Context) {
        host.viewportScale = zoom?.scale ?? 1
        tab.webView.pageZoom = zoom?.scale ?? 1
        tab.webView.setAccessibilityHidden(tab.hasNativeSheet)
        let becameFocusable = !host.allowsKeyboardFocus && allowsKeyboardFocus
        host.allowsKeyboardFocus = allowsKeyboardFocus
        host.setVisible(isVisible)
        if becameFocusable && isVisible { host.requestKeyboardFocus() }
    }

    static func dismantleNSView(_ host: RetainedContentHost<WKWebView>, coordinator: Void) { host.setVisible(false) }
}

struct NewBrowserTabButton: View {
    @Environment(BrowserTabsModel.self) private var browsers
    var body: some View {
        Button {
            browsers.create()
        } label: {
            Label("New Browser Tab", systemImage: "globe")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small)
        .buttonSizing(.flexible)
        .frame(width: WorkflowTabLayout.creationButtonWidth, height: WorkflowTabLayout.height)
        .help("New Browser Tab (⌥⌘T)").accessibilityIdentifier("newBrowserTab")
    }
}
