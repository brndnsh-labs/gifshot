import CoreGraphics
import Foundation

/// Decides which captured frames reach the `GIFWriter`.
///
/// Frames identical to the previous one are skipped (the previous frame just stays on screen
/// longer). Frames whose changed area covers more than `largeChange` of the picture (scrolling,
/// video, dragged windows) are limited to `fullMotionFPS`, because each one costs nearly a whole
/// frame of GIF bytes. Small changes (cursor, typing, spinners) pass at the full capture rate.
///
/// A large-change frame that arrives too soon is held instead of dropped: the next frame replaces
/// it, or, if none arrives in time, `flushHeld` writes it so the final state of a scroll is kept.
///
/// Not thread-safe: use from one serial queue, the same one the writer is used from.
nonisolated final class FrameThrottle {
    static let largeChange = 0.25

    private let writer: GIFWriter
    private let minInterval: Double
    private var previous: Data?
    private var held: (image: CGImage, time: Double)?
    private var lastAdded = -Double.infinity

    init(writer: GIFWriter, fullMotionFPS: Int) {
        self.writer = writer
        minInterval = 0.9 / Double(fullMotionFPS)  // slack for timestamp jitter
    }

    /// Takes a BGRA frame captured at `time` (host clock seconds). If the frame is held back,
    /// returns when to call `flushHeld`.
    func add(_ pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int,
             at time: Double) -> Double? {
        let size = bytesPerRow * height
        var area = width * height
        if let previous, previous.count == size {
            area = previous.withUnsafeBytes { changedArea(pixels, $0.baseAddress!, bytesPerRow, width, height) }
            if area == 0 { return nil }
        }
        let data = Data(bytes: pixels, count: size)  // ScreenCaptureKit reuses its buffers
        let large = previous != nil && Double(area) > Self.largeChange * Double(width * height)
        previous = data
        guard let image = Self.image(data, bytesPerRow: bytesPerRow, width: width, height: height) else {
            return nil
        }
        if large && time - lastAdded < minInterval {
            held = (image, time)
            return time + minInterval
        }
        held = nil
        lastAdded = time
        writer.add(image, at: time)
        return nil
    }

    /// Writes the held frame if no newer frame has arrived since it was held.
    func flushHeld(at now: Double) {
        guard let held, now >= held.time + minInterval - 0.002 else { return }
        self.held = nil
        lastAdded = held.time
        writer.add(held.image, at: held.time)
    }

    func finish(at time: Double) -> Bool {
        if let held { writer.add(held.image, at: held.time) }
        held = nil
        return writer.finish(at: time)
    }

    /// Area of the bounding box of the pixels that differ between two frames.
    private func changedArea(_ new: UnsafeRawPointer, _ old: UnsafeRawPointer, _ bytesPerRow: Int,
                             _ width: Int, _ height: Int) -> Int {
        var top = -1, bottom = -1, left = width, right = -1
        for y in 0 ..< height {
            let a = new + y * bytesPerRow, b = old + y * bytesPerRow
            guard memcmp(a, b, width * 4) != 0 else { continue }
            if top < 0 { top = y }
            bottom = y
            // Only the columns outside the box found so far need scanning.
            let p = a.assumingMemoryBound(to: UInt32.self), q = b.assumingMemoryBound(to: UInt32.self)
            var x = 0
            while x < left, p[x] == q[x] { x += 1 }
            left = min(left, x)
            x = width - 1
            while x > right, p[x] == q[x] { x -= 1 }
            right = max(right, x)
        }
        return top < 0 ? 0 : (bottom - top + 1) * (right - left + 1)
    }

    private static func image(_ data: Data, bytesPerRow: Int, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                           | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
