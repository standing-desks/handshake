import AVFoundation
import AppKit
import Observation
import PDFKit

@Observable
final class MediaPreviewModel {
    private(set) var pdf: PDFDocument?
    private(set) var image: NSImage?
    private(set) var player: AVPlayer?
    private(set) var failure: String?
    private(set) var isLoaded = false
    private var stamp: MediaFileStamp?
    private var observation: NSKeyValueObservation?
    private var generation = UUID()

    func load(path: String, folder: String, format: FilePreviewFormat) async {
        let request = UUID()
        generation = request
        do {
            let next = try await MediaFileStamp.resolve(path: path, folder: folder)
            guard !Task.isCancelled, generation == request else { return }
            guard stamp != next || failure != nil else { return }
            pause()
            observation?.invalidate()
            pdf = nil
            image = nil
            player = nil
            isLoaded = false
            failure = nil
            try await read(next.url, format: format, request: request)
            guard !Task.isCancelled, generation == request else { return }
            stamp = next
            isLoaded = true
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            failure = error.localizedDescription
        }
    }

    private func read(_ url: URL, format: FilePreviewFormat, request: UUID) async throws {
        switch format {
        case .pdf:
            let document = await Self.readPDF(url)
            guard !Task.isCancelled, generation == request else { return }
            guard let document, document.pageCount > 0 else { throw MediaError.unreadable }
            pdf = document
        case .image:
            let decoded = await Self.readImage(url)
            guard !Task.isCancelled, generation == request else { return }
            guard let decoded else { throw MediaError.unreadable }
            image = decoded
        case .video:
            try await readVideo(url, request: request)
        case .html, .markdown:
            throw MediaError.unreadable
        }
    }

    private func readVideo(_ url: URL, request: UUID) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw MediaError.unreadable }
        guard !Task.isCancelled, generation == request else { return }
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, player?.currentItem === item, failed else { return }
                failure = "This video could not be played. Its format or codec may not be supported."
            }
        }
    }

    func pause() { player?.pause() }

    @concurrent private static func readPDF(_ url: URL) async -> sending PDFDocument? { PDFDocument(url: url) }
    @concurrent private static func readImage(_ url: URL) async -> sending NSImage? { NSImage(contentsOf: url) }
}

nonisolated private enum MediaError: LocalizedError {
    case unreadable, outsideFolder
    var errorDescription: String? {
        switch self {
        case .unreadable: "This file could not be previewed. Its format may be unsupported or the file may be damaged."
        case .outsideFolder: "Only regular files inside the opened folder can be previewed."
        }
    }
}

nonisolated private struct MediaFileStamp: Equatable, Sendable {
    let url: URL
    let modified: Date?
    let size: Int?

    @concurrent static func resolve(path: String, folder: String) async throws -> Self {
        let original = URL(filePath: path)
        let values = try original.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
            let location = await HTMLPreviewLocation.resolve(file: original, folder: URL(filePath: folder))
        else { throw MediaError.outsideFolder }
        let metadata = try location.file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Self(url: location.file, modified: metadata.contentModificationDate, size: metadata.fileSize)
    }
}
