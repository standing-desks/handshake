import AppKit
import CoreText
import MetalKit
import Testing

@testable import Handshake
@testable import SwiftTerm

struct TerminalGlyphAlignmentTests {
    @Test @MainActor func coreGraphicsCaretUsesTheParentPixelGrid() throws {
        let font = try #require(NSFont(name: "Menlo-Regular", size: 12))
        let terminal = MetalTerminalView(frame: .zero)
        terminal.automaticallyFocuses = false
        terminal.applyHandshakeFont(font)
        terminal.caretColor = .white
        terminal.caretTextColor = .black
        let bounds = CGRect(
            origin: .zero, size: CGSize(width: terminal.cellDimension.width, height: terminal.cellDimension.height))
        let caret = CaretView(frame: bounds, cursorStyle: .steadyBlock, terminal: terminal)
        caret.ctline = CTLineCreateWithAttributedString(NSAttributedString(string: "I", attributes: [.font: font]))
        var character = UniChar(73)
        var glyph = CGGlyph(0)
        try #require(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        let baseline = ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
        let origin = CGPoint(x: 8.3, y: 8.3)
        for scale: CGFloat in [1, 2, 3] {
            for lineScale: CGFloat in [1, 2] {
                let pixelScale = scale * lineScale
                let size = 192
                func bitmap() throws -> CGContext {
                    let context = try #require(
                        CGContext(
                            data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
                    context.scaleBy(x: pixelScale, y: pixelScale)
                    return context
                }
                let actual = try bitmap()
                actual.translateBy(x: origin.x, y: origin.y)
                caret.drawCursor(in: actual, hasFocus: true)
                let expected = try bitmap()
                expected.setFillColor(NSColor.black.cgColor)
                var position = CGPoint(
                    x: (origin.x * pixelScale).rounded() / pixelScale,
                    y: ((origin.y + baseline) * pixelScale).rounded() / pixelScale)
                CTFontDrawGlyphs(font, &glyph, &position, 1, expected)
                let actualBytes = UnsafeRawBufferPointer(start: try #require(actual.data), count: size * size * 4)
                let expectedBytes = UnsafeRawBufferPointer(start: try #require(expected.data), count: size * size * 4)
                // noneSkipLast's fourth byte is padding, not rendered image content.
                let matches = actualBytes.indices.filter { $0 % 4 != 3 }.allSatisfy {
                    actualBytes[$0] == expectedBytes[$0]
                }
                #expect(matches, "Caret pixels differ from the parent grid at scale \(pixelScale)")
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    @MainActor func metalGlyphsUseDevicePixelsAfterDoubleHeightTransforms() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for scale: CGFloat in [1, 1.25, 2, 3] {
            let frame = CGRect(x: 0, y: 0, width: 360, height: 180.3)
            let terminal = MetalTerminalView(frame: frame)
            terminal.automaticallyFocuses = false
            terminal.caretViewTracksFocus = false
            terminal.feed(text: "ASCII\r\n\u{1B}#6wide\r\n\u{1B}#3double\r\n\u{1B}#4double\r\n")
            let target = MTKView(frame: frame, device: device)
            let renderer = try MetalTerminalRenderer(view: target, terminalView: terminal)
            let data = renderer.debugBuildDrawData(scale: scale)
            var count = 0
            for (index, row) in data.rows.enumerated() {
                guard let buffer = row.glyphGrayBuffer else { continue }
                let cells = buffer.contents().bindMemory(to: TextCell.self, capacity: row.glyphGrayCount)
                let lowerClip = Float((frame.height - terminal.cellDimension.height * CGFloat(index + 1)) * scale)
                let upperClip = lowerClip + Float(terminal.cellDimension.height * scale)
                for cell in UnsafeBufferPointer(start: cells, count: row.glyphGrayCount) {
                    count += 1
                    #expect(abs(cell.position.x - cell.position.x.rounded()) < 0.001)
                    let bottom = cell.position.y
                    let top = bottom + cell.size.y
                    // Doubled rows clip at fractional boundaries; the unclipped bitmap edge stays aligned.
                    if abs(bottom - bottom.rounded()) >= 0.001 {
                        #expect(abs(bottom - lowerClip) < 0.001)
                        #expect(abs(top - top.rounded()) < 0.001 || abs(top - upperClip) < 0.001)
                    }
                }
            }
            #expect(count > 0)
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    @MainActor func metalCursorUsesTheSameBitmapPlacementAsTextAndEmoji() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for scale: CGFloat in [1, 1.25, 2, 3] {
            for text in ["W", "😀"] {
                let frame = CGRect(x: 0, y: 0, width: 120, height: 80.3)
                let terminal = MetalTerminalView(frame: frame)
                terminal.automaticallyFocuses = false
                terminal.applyHandshakeFont(.monospacedSystemFont(ofSize: 16, weight: .regular))
                terminal.caretViewTracksFocus = false
                terminal.feed(text: "\(text)\u{1B}[1G\u{1B}[2 q")
                let target = MTKView(frame: frame, device: device)
                let renderer = try MetalTerminalRenderer(view: target, terminalView: terminal)
                let data = renderer.debugBuildDrawData(scale: scale)
                let row = try #require(data.rows.first)
                let isColor = text == "😀"
                let buffer = try #require(isColor ? row.glyphColorBuffer : row.glyphGrayBuffer)
                #expect((isColor ? row.glyphColorCount : row.glyphGrayCount) == 1)
                let cell = buffer.contents().load(as: TextCell.self)
                let vertices = isColor ? data.cursorGlyphVerticesColor : data.cursorGlyphVerticesGray
                try #require(vertices.count == 6, "Missing cursor glyph for \(text) at scale \(scale)")
                for vertex in vertices {
                    let expected = cell.texOrigin + (vertex.position - cell.position) * cell.texSize / cell.size
                    #expect(abs(vertex.texCoord.x - expected.x) < 0.00001)
                    #expect(abs(vertex.texCoord.y - expected.y) < 0.00001)
                }
            }
        }
    }
}
