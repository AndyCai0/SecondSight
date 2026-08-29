import AppKit
import CoreImage
import CoreVideo
import Foundation
import SecondSightCore

enum RedactedJPEGEncoder {
    static func encode(_ pixelBuffer: CVPixelBuffer, maximumLongEdge: Int = 1_568) -> Data? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let fitted = ImageSizing.fittedSize(width: sourceWidth, height: sourceHeight, maximumLongEdge: maximumLongEdge)
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let scaleX = CGFloat(fitted.width) / CGFloat(sourceWidth)
        let scaleY = CGFloat(fitted.height) / CGFloat(sourceHeight)
        let image = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: fitted.width, height: fitted.height)) else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }
}
