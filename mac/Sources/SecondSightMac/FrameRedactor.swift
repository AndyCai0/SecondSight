import CoreImage
import CoreVideo
import Foundation
import SecondSightCore

final class FrameRedactor: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func redact(source: CVPixelBuffer, snapshot: RedactionSnapshot, displayFramePoints: CGRect) -> CVPixelBuffer? {
        guard !snapshot.protectionUnavailable,
              !(snapshot.secureInputEnabled && snapshot.axRects.isEmpty)
        else {
            // Never substitute a full-display mask. The publisher simply
            // pauses, leaving the last frame that already passed redaction.
            return nil
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let output = makeBuffer(width: width, height: height) else { return nil }
        let sourceImage = CIImage(cvPixelBuffer: source)
        context.render(sourceImage, to: output, bounds: sourceImage.extent, colorSpace: CGColorSpaceCreateDeviceRGB())

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

}
