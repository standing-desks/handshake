// Maintenance only: swift assets/render-pngs.swift [output-folder]
// AppKit renders the source SVGs into PNG sizes for the website and favicons.
import AppKit

let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let output =
  CommandLine.arguments.count > 1
  ? URL(fileURLWithPath: CommandLine.arguments[1])
  : folder.appendingPathComponent("png")
let names = [
  "app-dark", "app-light", "transparent", "avatar-dark", "avatar-light",
  "square-dark", "square-light",
]
let sizes = [16, 24, 32, 48, 64, 128, 256, 512]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for name in names {
  let file = "handshake-\(name)"
  guard let image = NSImage(contentsOf: folder.appendingPathComponent("\(file).svg")) else {
    fatalError("Cannot read \(file).svg")
  }
  for size in sizes {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      fatalError("Cannot create \(size) px bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
      in: CGRect(x: 0, y: 0, width: size, height: size), from: .zero,
      operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      fatalError("Cannot encode \(file)-\(size).png")
    }
    try data.write(to: output.appendingPathComponent("\(file)-\(size).png"))
  }
}
print("Wrote \(names.count * sizes.count) PNGs to \(output.path)")
