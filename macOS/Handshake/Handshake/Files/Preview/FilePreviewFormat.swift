import Foundation
import UniformTypeIdentifiers

nonisolated enum FilePreviewFormat: Sendable {
    case html, markdown, pdf, image, video

    init?(path: String) {
        let ext = URL(filePath: path).pathExtension.lowercased()
        switch ext {
        case "html", "htm": self = .html
        case "md", "markdown": self = .markdown
        case "pdf": self = .pdf
        default:
            guard let type = UTType(filenameExtension: ext) else { return nil }
            if type.conforms(to: .image) {
                self = .image
            } else if type.conforms(to: .movie) {
                self = .video
            } else {
                return nil
            }
        }
    }

    var isNative: Bool { self == .pdf || self == .image || self == .video }
    var name: String {
        switch self {
        case .html: "HTML"
        case .markdown: "Markdown"
        case .pdf: "PDF"
        case .image: "Image"
        case .video: "Video"
        }
    }
    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .video: "film"
        case .html, .markdown: "doc.text"
        }
    }
    var accessibilityPrefix: String { name.lowercased() }
}
