import CoreVideo
import Foundation
import SecondSightCore
import Vision

/// Supplements Accessibility with local-only pixel inspection for content that
/// canvas, PDF, image, or custom-rendered views do not expose as AX nodes.
/// Results are recalculated only after a significant screen change and are
/// never uploaded before redaction.
final class VisualPrivacyScanner {
    private var baseline: [UInt8]?
    private var lastRects: [CGRect] = []

    func redactionRects(
        for frame: CVPixelBuffer,
        displayFramePoints: CGRect
    ) throws -> [CGRect] {
        guard let signature = Self.signature(for: frame) else {
            throw VisualPrivacyError.unsupportedFrame
        }
        guard ScreenChangePolicy.isSignificant(previous: baseline, current: signature) else {
            return lastRects
        }

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        textRequest.minimumTextHeight = 0.008

        let faceRequest = VNDetectFaceRectanglesRequest()
        let barcodeRequest = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:])
        try handler.perform([textRequest, faceRequest, barcodeRequest])

        var rects: [CGRect] = []
        for observation in textRequest.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string,
                  StaticPrivacyPolicy.containsSensitiveContent(text)
            else { continue }
            rects.append(VisionPrivacyGeometry.topLeftRect(
                forNormalizedBottomLeftRect: observation.boundingBox,
                displayFramePoints: displayFramePoints
            ))
        }
        for observation in faceRequest.results ?? [] {
            let rect = VisionPrivacyGeometry.topLeftRect(
                forNormalizedBottomLeftRect: observation.boundingBox,
                displayFramePoints: displayFramePoints
            )
            rects.append(rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.12))
        }
        for observation in barcodeRequest.results ?? [] {
            rects.append(VisionPrivacyGeometry.topLeftRect(
                forNormalizedBottomLeftRect: observation.boundingBox,
                displayFramePoints: displayFramePoints
            ))
        }

        baseline = signature
        lastRects = Self.deduplicated(rects)
        return lastRects
    }

    func reset() {
        baseline = nil
        lastRects = []
    }

    private static func signature(for frame: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(frame) else { return nil }

        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(frame)
        guard width > 0, height > 0 else { return nil }

        let columns = min(48, width)
        let rows = min(27, height)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        var result: [UInt8] = []
        result.reserveCapacity(columns * rows * 3)
        for row in 0 ..< rows {
            let y = min(height - 1, (row * height + height / (rows * 2)) / rows)
            for column in 0 ..< columns {
                let x = min(width - 1, (column * width + width / (columns * 2)) / columns)
                let offset = y * bytesPerRow + x * 4
                result.append(pixels[offset + 2])
                result.append(pixels[offset + 1])
                result.append(pixels[offset])
            }
        }
        return result
    }

    private static func deduplicated(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects where !rect.isNull && !rect.isEmpty {
            let integral = rect.integral
            if !result.contains(where: { $0 == integral }) {
                result.append(integral)
            }
        }
        return result
    }

    private enum VisualPrivacyError: Error {
        case unsupportedFrame
    }
}
