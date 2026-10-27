import AVFoundation
import AppKit
import Foundation
import PDFKit
import Testing

@testable import Handshake

@MainActor
struct MediaPreviewTests {
    @Test func nativeFormatsDoNotDependOnTheTextPreviewLimit() {
        for path in [
            "page.PDF", "photo.png", "photo.jpeg", "photo.heic", "photo.gif", "art.svg", "clip.mov", "clip.mp4",
        ] {
            #expect(FilePreviewFormat(path: path)?.isNative == true)
        }
        #expect(FilePreviewFormat(path: "README.md") == .markdown)
        #expect(FilePreviewFormat(path: "source.swift") == nil)
    }

    @Test func nativeDocumentsLoadRetainIdentityAndReportCorruptFiles() async throws {
        let temporary = TemporaryPath()
        try await MediaFixtures.make(in: temporary.url)
        let pdf = MediaPreviewModel()
        await pdf.load(path: temporary.url.appending(path: "sample.pdf").path, folder: temporary.url.path, format: .pdf)
        #expect(pdf.failure == nil)
        #expect(pdf.pdf?.page(at: 0)?.string?.contains("Handshake PDF fixture") == true)
        let document = pdf.pdf
        await pdf.load(path: temporary.url.appending(path: "sample.pdf").path, folder: temporary.url.path, format: .pdf)
        #expect(pdf.pdf === document)
        let image = MediaPreviewModel()
        await image.load(
            path: temporary.url.appending(path: "sample.png").path, folder: temporary.url.path, format: .image)
        #expect(image.image?.size.width == 160)
        #expect(image.failure == nil)
        let corrupt = temporary.url.appending(path: "bad.pdf")
        try Data("broken".utf8).write(to: corrupt)
        await pdf.load(path: corrupt.path, folder: temporary.url.path, format: .pdf)
        #expect(pdf.failure != nil)
    }

    @Test func videoCanPlayPauseAndRetainItsPosition() async throws {
        let temporary = TemporaryPath()
        try await MediaFixtures.make(in: temporary.url)
        let model = MediaPreviewModel()
        let path = temporary.url.appending(path: "sample.mov").path
        await model.load(path: path, folder: temporary.url.path, format: .video)
        #expect(model.failure == nil)
        let player = try #require(model.player)
        player.play()
        for _ in 0..<200 {
            if player.currentTime().seconds > 0.15 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        model.pause()
        #expect(player.rate == 0)
        #expect(player.currentTime().seconds > 0.15)
        let time = player.currentTime().seconds
        await model.load(path: path, folder: temporary.url.path, format: .video)
        #expect(model.player === player)
        #expect(abs(player.currentTime().seconds - time) < 0.1)
        let playback = try #require(model.playback)
        #expect(abs(playback.duration - 10) < 0.05)
        playback.seek(to: 1.5)
        for _ in 0..<100 {
            if abs(playback.position - 1.5) < 0.1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(abs(player.currentTime().seconds - 1.5) < 0.1)
        #expect(abs(playback.position - 1.5) < 0.1)
    }

    @Test func nativePreviewsRejectSymlinksAndPathsOutsideTheFolder() async throws {
        let temporary = TemporaryPath()
        let folder = temporary.url.appending(path: "folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = temporary.url.appending(path: "secret.pdf")
        try Data().write(to: outside)
        let link = folder.appending(path: "link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for path in [outside.path, link.path, folder.path] {
            let model = MediaPreviewModel()
            await model.load(path: path, folder: folder.path, format: .pdf)
            #expect(model.failure != nil)
            #expect(!model.isLoaded)
        }
    }
}
