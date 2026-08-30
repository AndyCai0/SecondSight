import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import SecondSightCore

final class LatestFrameStore: @unchecked Sendable {
    struct Snapshot {
        let frame: CVPixelBuffer
        let axSummary: String?
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?

    func set(_ frame: CVPixelBuffer, axSummary: String?) {
        lock.lock(); snapshot = Snapshot(frame: frame, axSummary: axSummary); lock.unlock()
    }

    func get() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return snapshot?.frame
    }

    func getSnapshot() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }

    func clear() {
        lock.lock(); snapshot = nil; lock.unlock()
    }
}

final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    let latestFrame = LatestFrameStore()

    private let scanner: AccessibilityScanner
    private let redactor = FrameRedactor()
    private let visualPrivacyScanner = VisualPrivacyScanner()
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
        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = content.applications.filter { application in
            application.bundleIdentifier == ownBundleID
                || CapturePrivacyPolicy.shouldExcludeApplication(bundleIdentifier: application.bundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
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
        scanner.protect(displayFramePoints: displayFramePoints)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        scanner.start()
        queue.sync { visualPrivacyScanner.reset() }
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
        queue.sync { visualPrivacyScanner.reset() }
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
              let source = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let accessibilitySnapshot = scanner.store.current()
        guard !accessibilitySnapshot.protectionUnavailable else {
            return
        }
        let visualRects: [CGRect]
        do {
            visualRects = try visualPrivacyScanner.redactionRects(
                for: source,
                displayFramePoints: displayFramePoints
            )
        } catch {
            return
        }
        let combinedSnapshot = RedactionSnapshot(
            axRects: accessibilitySnapshot.axRects + visualRects,
            secureInputEnabled: accessibilitySnapshot.secureInputEnabled,
            protectionUnavailable: false,
            axSummary: accessibilitySnapshot.axSummary
        )
        guard let output = redactor.redact(
            source: source,
            snapshot: combinedSnapshot,
            displayFramePoints: displayFramePoints
        ) else { return }
        // AX summary nodes are already stripped for AX masks. A Vision-only
        // face/barcode/OCR rectangle has no corresponding AX privacy flag, so
        // omit the summary for this frame rather than reintroducing content
        // through a side channel.
        let safeAXSummary = visualRects.isEmpty ? accessibilitySnapshot.axSummary : nil
        latestFrame.set(output, axSummary: safeAXSummary)
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
