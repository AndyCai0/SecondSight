import AppKit
import CoreImage
import CoreText
import CoreVideo
import Foundation
import SecondSightCore

final class FrameRedactor: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func redact(source: CVPixelBuffer, snapshot: RedactionSnapshot, displayFramePoints: CGRect) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let output = makeBuffer(width: width, height: height) else { return nil }
        let sourceImage = CIImage(cvPixelBuffer: source)
        context.render(sourceImage, to: output, bounds: sourceImage.extent, colorSpace: CGColorSpaceCreateDeviceRGB())

        if snapshot.secureInputEnabled && snapshot.axRects.isEmpty {
            drawSecurePlaceholder(in: output)
            return output
        }
        let geometry = CaptureGeometry(
            displayFramePoints: displayFramePoints,
            frameSizePixels: CGSize(width: width, height: height)
        )
        fillBlack(snapshot.axRects.map { geometry.pixelRect(forAXTopLeftRect: $0) }, in: output)
        return output
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }

    private func fillBlack(_ rects: [CGRect], in buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let wordsPerRow = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt32>.size
        let pixels = base.assumingMemoryBound(to: UInt32.self)
        for rawRect in rects where !rawRect.isNull && !rawRect.isEmpty {
            let rect = rawRect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            let minX = max(0, Int(rect.minX)); let maxX = min(width, Int(rect.maxX))
            let minY = max(0, Int(rect.minY)); let maxY = min(height, Int(rect.maxY))
            guard minX < maxX, minY < maxY else { continue }
            for y in minY ..< maxY {
                for x in minX ..< maxX { pixels[y * wordsPerRow + x] = 0xFF00_0000 }
            }
        }
    }

    private func drawSecurePlaceholder(in buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let cg = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        cg.setFillColor(NSColor(calibratedWhite: 0.18, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let fontSize = max(30, min(64, CGFloat(width) / 24))
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("PingFang SC" as CFString, fontSize, nil),
            kCTForegroundColorAttributeName: NSColor.white.cgColor,
        ]
        let text = "正在输入敏感信息，画面已暂停"
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        cg.textPosition = CGPoint(x: max(20, (CGFloat(width) - bounds.width) / 2), y: CGFloat(height) / 2)
        CTLineDraw(line, cg)
    }
}
