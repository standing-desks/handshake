import AVFoundation
import AppKit
import CoreText
import PDFKit

/// Small native fixtures avoid codec tools or downloaded test media.
@MainActor
enum MediaFixtures {
    static func make(in folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { throw FixtureError.failed }
        try png.write(to: folder.appending(path: "sample.png"))
        try (png + Data(repeating: 0, count: 3 * 1024 * 1024)).write(to: folder.appending(path: "sample-large.png"))
        try makePDF(at: folder.appending(path: "sample.pdf"))
        try await makeVideo(at: folder.appending(path: "sample.mov"))
    }

    private static func makePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw FixtureError.failed }
        context.beginPDFPage(nil)
        let text = NSAttributedString(
            string: "Handshake PDF fixture", attributes: [.font: NSFont.systemFont(ofSize: 24)])
        context.textPosition = CGPoint(x: 24, y: 420)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
    }

    private static func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 100,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 100,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw FixtureError.failed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw FixtureError.failed }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer
            else { throw FixtureError.failed }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let bytes = CVPixelBufferGetBaseAddress(buffer) {
                memset(bytes, Int32(40 + frame), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw FixtureError.failed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError.failed }
    }

    private enum FixtureError: Error { case failed }
}
