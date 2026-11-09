// 앱 아이콘 SVG를 투명 바탕 PNG로 그립니다 (M6(3), scripts/make-app-icon.sh가 부름).
// macOS의 NSImage가 SVG를 직접 읽으므로 따로 도구를 설치하지 않아도 됩니다.
//   swift scripts/render-icon.swift <입력.svg> <크기(px)> <출력.png>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let pixels = Int(arguments[2]), let image = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("사용법: render-icon.swift <입력.svg> <크기> <출력.png>\n".utf8))
    exit(2)
}
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
// 포인트 크기 = 픽셀 크기 (배율 1)로 맞춰야 PNG에 72dpi로 기록되어 Xcode가 크기 경고를 내지 않습니다
bitmap.size = NSSize(width: pixels, height: pixels)
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.set()
NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: arguments[3]))
