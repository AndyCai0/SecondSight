import CoreVideo
import Foundation
import SecondSightCore

final class SignificantScreenChangeMonitor: @unchecked Sendable {
    struct Candidate: Sendable {
        let revision: Int
        fileprivate let signature: [UInt8]
    }

    private let lock = NSLock()
    private var baseline: [UInt8]?
    private var nextRevision = 1

    func candidate(for frame: CVPixelBuffer) -> Candidate? {
        guard let signature = Self.signature(for: frame) else { return nil }
        return lock.withLock {
            guard ScreenChangePolicy.isSignificant(previous: baseline, current: signature) else {
                return nil
            }
            let candidate = Candidate(revision: nextRevision, signature: signature)
            nextRevision += 1
            return candidate
        }
    }

    func commit(_ candidate: Candidate) {
        lock.withLock { baseline = candidate.signature }
    }

    func reset() {
        lock.withLock {
            baseline = nil
            nextRevision = 1
        }
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
        var result = [UInt8]()
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
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
