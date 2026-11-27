import Foundation

/// Decides which captured frames reach the `GIFWriter`.
///
/// Frames identical to the previous one are skipped (the previous frame just stays on screen
/// longer). Frames whose changed area covers more than `largeChange` of the picture (scrolling,
/// video, dragged windows) are limited to `fullMotionFPS`, because each one costs nearly a whole
/// frame of GIF bytes. Small changes (cursor, typing, spinners) pass at the full capture rate, but
/// never closer than 2 cs, the shortest delay GIF viewers honor.
///
/// A frame that arrives too soon is held instead of dropped: the next frame replaces it, or, if
/// none arrives in time, `flushHeld` writes it so the final state of a scroll is kept.
///
/// Not thread-safe: use from one serial queue, the same one the writer is used from.
nonisolated final class FrameThrottle {
    static let largeChange = 0.25
    static let minimumInterval = 0.02

    private let writer: GIFWriter
    private let largeInterval: Double
    private var previous: UnsafeMutableRawPointer?  // last frame received; also the held frame
    private var previousBytesPerRow = 0
    private var held: (time: Double, deadline: Double)?
    private var lastAdded = -Double.infinity

    init(writer: GIFWriter, fullMotionFPS: Int) {
        self.writer = writer
        largeInterval = 0.9 / Double(fullMotionFPS)  // slack for timestamp jitter
    }

    deinit { previous?.deallocate() }

    /// Takes a BGRA frame captured at `time` (host clock seconds). Frames of the wrong size are
    /// ignored. If the frame is held back, returns when to call `flushHeld`.
    func add(_ pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int,
             at time: Double) -> Double? {
        guard width == writer.width, height == writer.height else { return nil }
        if previous == nil || previousBytesPerRow != bytesPerRow {
            previous?.deallocate()
            previous = .allocate(byteCount: bytesPerRow * height, alignment: 16)
            previousBytesPerRow = bytesPerRow
        } else if let area = changedArea(pixels, previous!, bytesPerRow, width, height) {
            let large = Double(area) > Self.largeChange * Double(width * height)
            let interval = large ? largeInterval : Self.minimumInterval
            if time - lastAdded < interval {
                previous!.copyMemory(from: pixels, byteCount: bytesPerRow * height)
                held = (time, time + interval)
                return time + interval
            }
        } else {
            return nil  // unchanged
        }
        previous!.copyMemory(from: pixels, byteCount: bytesPerRow * height)
        held = nil
        lastAdded = time
        writer.add(pixels, bytesPerRow: bytesPerRow, at: time)
        return nil
    }

    /// Writes the held frame if no newer frame has replaced it in time.
    func flushHeld(at now: Double) {
        guard let held, let previous, now >= held.deadline - 0.002 else { return }
        self.held = nil
        lastAdded = held.time
        writer.add(previous, bytesPerRow: previousBytesPerRow, at: held.time)
    }

    func finish(at time: Double) -> Bool {
        if let held, let previous { writer.add(previous, bytesPerRow: previousBytesPerRow, at: held.time) }
        held = nil
        return writer.finish(at: time)
    }

    /// Area of the bounding box of the pixels that differ between two frames, or nil if none do.
    private func changedArea(_ new: UnsafeRawPointer, _ old: UnsafeRawPointer, _ bytesPerRow: Int,
                             _ width: Int, _ height: Int) -> Int? {
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
        return top < 0 ? nil : (bottom - top + 1) * (right - left + 1)
    }
}
