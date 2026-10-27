import AVKit
import PDFKit
import SwiftUI

/// Native file previews retain their document/player while other workspace tabs are selected.
struct MediaPreview: View {
    let file: FilePreview
    let folder: String
    let format: FilePreviewFormat
    let isVisible: Bool
    var allowsAutomaticFocus = true
    @State private var media = MediaPreviewModel()

    var body: some View {
        ZStack {
            if let failure = media.failure {
                ContentUnavailableView("Preview Unavailable", systemImage: format.symbol, description: Text(failure))
                    .accessibilityIdentifier("mediaFailure")
            } else if media.isLoaded {
                switch format {
                case .pdf:
                    PDFPreview(document: media.pdf, isVisible: isVisible, allowsAutomaticFocus: allowsAutomaticFocus)
                case .image:
                    ImagePreview(image: media.image, isVisible: isVisible)
                case .video:
                    VideoPreview(player: media.player, isVisible: isVisible, allowsAutomaticFocus: allowsAutomaticFocus)
                case .html, .markdown:
                    EmptyView()
                }
            } else {
                ProgressView("Loading preview…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(format.accessibilityPrefix)Preview")
        .task(id: Request(file: file, folder: folder, visible: isVisible)) {
            guard isVisible else {
                media.pause()
                return
            }
            await media.load(path: file.path, folder: folder, format: format)
        }
        .onDisappear { media.pause() }
    }

    private struct Request: Equatable {
        let file: FilePreview
        let folder: String
        let visible: Bool
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument?
    let isVisible: Bool
    var allowsAutomaticFocus = true
    func makeNSView(context: Context) -> RetainedContentHost<PDFView> {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.setAccessibilityIdentifier("pdfDocument")
        return RetainedContentHost(content: view, responder: view)
    }
    func updateNSView(_ host: RetainedContentHost<PDFView>, context: Context) {
        if host.content.document !== document { host.content.document = document }
        host.allowsKeyboardFocus = allowsAutomaticFocus
        host.setVisible(isVisible)
    }
}

private struct ImagePreview: NSViewRepresentable {
    let image: NSImage?
    let isVisible: Bool
    var allowsAutomaticFocus = true
    func makeNSView(context: Context) -> RetainedContentHost<NSImageView> {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setAccessibilityIdentifier("imageDocument")
        return RetainedContentHost(content: view, responder: view)
    }
    func updateNSView(_ host: RetainedContentHost<NSImageView>, context: Context) {
        if host.content.image !== image { host.content.image = image }
        host.focusesOnShow = false
        host.allowsKeyboardFocus = allowsAutomaticFocus
        host.setVisible(isVisible)
    }
}

private struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer?
    let isVisible: Bool
    var allowsAutomaticFocus = true
    func makeNSView(context: Context) -> RetainedContentHost<AVPlayerView> {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.setAccessibilityIdentifier("videoPlayer")
        return RetainedContentHost(content: view, responder: view)
    }
    func updateNSView(_ host: RetainedContentHost<AVPlayerView>, context: Context) {
        if host.content.player !== player { host.content.player = player }
        if !isVisible { player?.pause() }
        host.allowsKeyboardFocus = allowsAutomaticFocus
        host.setVisible(isVisible)
    }
    static func dismantleNSView(_ host: RetainedContentHost<AVPlayerView>, coordinator: Void) {
        host.content.player?.pause()
        host.content.player = nil
        host.setVisible(false)
    }
}
