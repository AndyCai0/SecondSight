import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?

    func set(_ frame: CVPixelBuffer) {
        lock.lock(); self.frame = frame; lock.unlock()
    }

    func get() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return frame
    }

    func clear() {
        lock.lock(); frame = nil; lock.unlock()
    }
}

final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    let latestFrame = LatestFrameStore()

    private let scanner: AccessibilityScanner
    private let redactor = FrameRedactor()
    private let queue = DispatchQueue(label: "study.secondsight.screen-capture", qos: .userInteractive)
    private var stream: SCStream?
    private var displayFramePoints = CGRect.zero
    // Accessed only on `queue`, including from the sample callback.
    private var isAcceptingFrames = false

    init(scanner: AccessibilityScanner) {
        self.scanner = scanner
    }

    func start() async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let bundleID = Bundle.main.bundleIdentifier
        let excluded = content.windows.filter { window in
            guard let bundleID else { return false }
            return window.owningApplication?.bundleIdentifier == bundleID
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        // TASK A is deliberately single-display. AX frames use logical points,
        // while SCDisplay dimensions are pixels on Retina displays.
        let logicalSize = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.frame.size ?? CGSize(width: display.width, height: display.height)
        displayFramePoints = CGRect(origin: .zero, size: logicalSize)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        scanner.start()
        queue.sync { isAcceptingFrames = true }
        do {
            try await stream.startCapture()
        } catch {
            queue.sync { isAcceptingFrames = false }
            try? stream.removeStreamOutput(self, type: .screen)
            self.stream = nil
            scanner.stop()
            throw error
        }
    }

    func stop() async {
        // Close the application-level frame gate first. queue.sync is the
        // barrier that waits for any callback already redacting a frame;
        // later ScreenCaptureKit callbacks are dropped.
        queue.sync { isAcceptingFrames = false }
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            // Drain callbacks enqueued between closing the gate and stopping
            // ScreenCaptureKit while the last redaction snapshot is present.
            queue.sync {}
            self.stream = nil
        }
        scanner.stop()
        latestFrame.clear()
    }

    func restart() async throws {
        await stop()
        try await start()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isAcceptingFrames,
              type == .screen,
              sampleBuffer.isValid,
              let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let output = redactor.redact(source: source, snapshot: scanner.store.current(), displayFramePoints: displayFramePoints)
        else { return }
        latestFrame.set(output)
        onFrame?(output)
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? {
            localized(
                "找不到可共享的主显示器。",
                "Could not find a primary display to share.",
                for: .savedOrSystemDefault
            )
        }
    }
}
