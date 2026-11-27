import AppKit
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case displayNotFound, noFrames

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "Couldn't find the display to record."
        case .noFrames: "No frames were captured."
        }
    }
}

/// One recording: an `SCStream` of a display (optionally cropped to a region) feeding a `GIFWriter`.
final class Recorder {
    static let fps = 30
    /// Rate for frames that change most of the picture; see `FrameThrottle`.
    static let fullMotionFPS = 15
    static let maxDuration: TimeInterval = 60

    private let stream: SCStream
    private let sink: FrameSink
    private let url: URL

    private init(stream: SCStream, sink: FrameSink, url: URL) {
        self.stream = stream
        self.sink = sink
        self.url = url
    }

    /// Starts recording `region` (global screen coordinates) on `screen`, or the whole screen if nil.
    /// `onFailure` is called on the main actor if the stream stops on its own.
    static func start(screen: NSScreen, region: NSRect?,
                      onFailure: @escaping @MainActor (Error) -> Void) async throws -> Recorder {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecorderError.displayNotFound
        }
        // Excluding by app (not by window) also hides windows created later, like the border.
        let pid = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications.filter { $0.processID == pid },
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        var source = CGRect(origin: .zero, size: screen.frame.size)
        if let region {
            // Display-local points with a top-left origin.
            source = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
                            width: region.width, height: region.height)
            config.sourceRect = source
        }
        // Downscale only, preserving aspect. ScreenCaptureKit does the scaling.
        let maxWidth: CGFloat = region == nil ? 1280 : 800
        let pixelWidth = source.width * screen.backingScaleFactor
        let scale = min(1, maxWidth / pixelWidth)
        config.width = max(2, Int((pixelWidth * scale).rounded()))
        config.height = max(2, Int((source.height * screen.backingScaleFactor * scale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true

        let url = Output.temporaryURL()
        let writer = try GIFWriter(url: url, width: config.width, height: config.height,
                                   maxFrames: Int(maxDuration + 5) * fps)
        let throttle = FrameThrottle(writer: writer, fullMotionFPS: fullMotionFPS)
        let sink = FrameSink(throttle: throttle) { error in
            Task { @MainActor in onFailure(error) }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        try await stream.startCapture()
        return Recorder(stream: stream, sink: sink, url: url)
    }

    /// Stops capture and finishes the file. Returns the temporary GIF's URL.
    func stop() async throws -> URL {
        let end = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try? await stream.stopCapture()
        guard await sink.finish(at: end) else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.noFrames
        }
        return url
    }
}

/// Receives frames on its own serial queue and hands them to the throttle. All throttle and writer
/// access happens on `queue`.
private nonisolated final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "zip.brndn.gifshot.frames", qos: .userInitiated)
    private let throttle: FrameThrottle
    private let onError: @Sendable (Error) -> Void

    init(throttle: FrameThrottle, onError: @escaping @Sendable (Error) -> Void) {
        self.throttle = throttle
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = info[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let flushAt = throttle.add(base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                   width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                                   at: sampleBuffer.presentationTimeStamp.seconds)
        if let flushAt {
            queue.asyncAfter(deadline: .now() + max(0, flushAt - Self.now())) {
                self.throttle.flushHeld(at: Self.now())
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }

    func finish(at time: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.throttle.finish(at: time)) }
        }
    }

    /// Host clock seconds, the clock ScreenCaptureKit timestamps frames with.
    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
