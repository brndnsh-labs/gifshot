import Foundation

/// Streams an animated GIF to disk as frames arrive, in constant memory.
///
/// Each frame is stored as a diff: only the rectangle that changed, with pixels that are still
/// within `tolerance` of what's on screen left transparent. Colors come from `Palette`. A frame is
/// written once the next frame's timestamp gives it a delay, so dropped or skipped frames don't
/// speed up playback. (ImageIO isn't used: its GIF encoder holds every frame until finalize.)
///
/// Not thread-safe: use from one serial queue.
nonisolated final class GIFWriter {
    /// A changed pixel within this distance per channel of what's already shown is left alone. It
    /// hides capture noise and video grain, which would otherwise make nearly every pixel change.
    static let tolerance = 4

    let width: Int, height: Int
    private let file: FileHandle
    private let maxFrames: Int
    private let previous: UnsafeMutablePointer<UInt32>  // last source frame added
    private let shown: UnsafeMutablePointer<UInt32>     // what a viewer displays (RGB only)
    private let indices: UnsafeMutablePointer<UInt8>
    private let palette = Palette()
    private let lzw = LZW()
    private var pending: (block: [UInt8], transparentIndex: Int?, time: Double)?
    private var origin: Double?
    private var elapsedCentiseconds = 0
    private var finished = false
    private(set) var frameCount = 0

    init(url: URL, width: Int, height: Int, maxFrames: Int) throws {
        precondition((1 ..< 65536).contains(width) && (1 ..< 65536).contains(height))
        self.width = width
        self.height = height
        self.maxFrames = maxFrames
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
        previous = .allocate(capacity: width * height)
        shown = .allocate(capacity: width * height)
        indices = .allocate(capacity: width * height)
        var header = Array("GIF89a".utf8) + Self.le16(width) + Self.le16(height)
        header += [0x70, 0, 0]  // no global color table
        header += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]  // loop forever
        file.write(Data(header))
    }

    deinit {
        previous.deallocate()
        shown.deallocate()
        indices.deallocate()
    }

    /// Adds a BGRA frame of `width` × `height` captured at `time` (seconds, any monotonic clock).
    /// Its delay is the time until the next frame. Frames should be at least 2 cs apart; a shorter
    /// delay is clamped, since viewers treat anything under 2 cs as 10 cs.
    func add(_ base: UnsafeRawPointer, bytesPerRow: Int, at time: Double) {
        guard !finished, frameCount < maxFrames else { return }
        let src = Pixels(base: base, bytesPerRow: bytesPerRow)
        let first = frameCount == 0
        guard let changed = first ? Box(left: 0, top: 0, right: width - 1, bottom: height - 1)
            : changedBox(src) else { return }

        // Mark the pixels that need updating, and shrink the box to them.
        var box = Box(left: width, top: height, right: -1, bottom: -1)
        for y in changed.top ... changed.bottom {
            let s = src.row(y), p = previous + y * width, v = shown + y * width, m = indices + y * width
            for x in changed.left ... changed.right {
                let c = s[x]
                let update = first || (c != p[x] && !Self.close(c, v[x]))
                p[x] = c
                m[x] = update ? 1 : 0
                if update {
                    box.left = min(box.left, x); box.right = max(box.right, x)
                    box.top = min(box.top, y); box.bottom = y
                }
            }
        }
        guard box.right >= 0 else { return }  // every change is within tolerance of what's shown

        let (colors, transparent) = palette.map(src, box, indices: indices, shown: shown, stride: width)
        let entries = colors.count + (transparent ? 1 : 0)
        var bits = 1
        while 1 << bits < entries { bits += 1 }

        var block: [UInt8] = [0x2C] + Self.le16(box.left) + Self.le16(box.top)
        block += Self.le16(box.width) + Self.le16(box.height) + [0x80 | UInt8(bits - 1)]  // local color table
        block.reserveCapacity(block.count + 3 << bits + box.width * box.height / 2)
        for i in 0 ..< 1 << bits {
            let c = i < colors.count ? colors[i] : 0
            block += [UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
        }
        lzw.encode(indices, stride: width, box, minimumCodeSize: max(2, bits), into: &block)

        writePending(until: time)
        pending = (block, transparent ? colors.count : nil, time)
        frameCount += 1
    }

    /// Writes the last frame (shown until `time`) and closes the file. Returns false if no frames
    /// were written.
    func finish(at time: Double) -> Bool {
        guard !finished else { return false }
        finished = true
        if let pending {
            let shown = time - pending.time
            writePending(until: pending.time + (shown > 0 && shown < 120 ? shown : 1.0 / 15))
        }
        file.write(Data([0x3B]))  // trailer
        try? file.close()
        return frameCount > 0
    }

    /// Bounding box of the pixels that differ from the previous frame, or nil if none do.
    private func changedBox(_ src: Pixels) -> Box? {
        var box = Box(left: width, top: -1, right: -1, bottom: -1)
        for y in 0 ..< height {
            let s = src.row(y), p = previous + y * width
            guard memcmp(s, p, width * 4) != 0 else { continue }
            if box.top < 0 { box.top = y }
            box.bottom = y
            // Only the columns outside the box found so far need scanning.
            var x = 0
            while x < box.left, s[x] == p[x] { x += 1 }
            box.left = min(box.left, x)
            x = width - 1
            while x > box.right, s[x] == p[x] { x -= 1 }
            box.right = max(box.right, x)
        }
        return box.top < 0 ? nil : box
    }

    @inline(__always) private static func close(_ a: UInt32, _ b: UInt32) -> Bool {
        abs(Int((a >> 16) & 0xFF) - Int((b >> 16) & 0xFF)) <= tolerance
            && abs(Int((a >> 8) & 0xFF) - Int((b >> 8) & 0xFF)) <= tolerance
            && abs(Int(a & 0xFF) - Int(b & 0xFF)) <= tolerance
    }

    private func writePending(until end: Double) {
        guard let pending else { return }
        let origin = self.origin ?? pending.time
        self.origin = origin
        // Round on the running total so per-frame rounding error never accumulates.
        let delay = max(2, Int(((end - origin) * 100).rounded()) - elapsedCentiseconds)
        elapsedCentiseconds += delay
        let flags: UInt8 = 0x04 | (pending.transparentIndex == nil ? 0 : 1)  // leave in place; transparency
        var bytes: [UInt8] = [0x21, 0xF9, 0x04, flags, UInt8(delay & 0xFF), UInt8(delay >> 8),
                              UInt8(pending.transparentIndex ?? 0), 0]
        bytes += pending.block
        file.write(Data(bytes))
        self.pending = nil
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
}

/// GIF's variable-width LZW, with a directly indexed dictionary (`child[prefix << 8 | index]`).
private nonisolated final class LZW {
    private let child = UnsafeMutablePointer<UInt16>.allocate(capacity: 4096 * 256)  // 0 = no entry
    private var used: [Int] = []
    private var codes: [UInt8] = []

    init() { child.initialize(repeating: 0, count: 4096 * 256) }
    deinit { child.deallocate() }

    /// Appends the image data (minimum code size byte, then sub-blocks) for `box` of `indices`.
    func encode(_ indices: UnsafePointer<UInt8>, stride: Int, _ box: Box, minimumCodeSize: Int,
                into block: inout [UInt8]) {
        let clear = 1 << minimumCodeSize, end = clear + 1
        var next = end + 1, size = minimumCodeSize + 1
        var buffer: UInt64 = 0, count = 0
        codes.removeAll(keepingCapacity: true)
        func put(_ code: Int) {
            buffer |= UInt64(code) << UInt64(count)
            count += size
            while count >= 8 {
                codes.append(UInt8(truncatingIfNeeded: buffer))
                buffer >>= 8
                count -= 8
            }
        }
        func reset() {
            for slot in used { child[slot] = 0 }
            used.removeAll(keepingCapacity: true)
        }

        put(clear)
        var prefix = -1
        for y in box.top ... box.bottom {
            let row = indices + y * stride
            for x in box.left ... box.right {
                let k = Int(row[x])
                if prefix < 0 { prefix = k; continue }
                let slot = prefix << 8 | k
                if child[slot] != 0 { prefix = Int(child[slot]); continue }
                put(prefix)
                if next < 4096 {
                    child[slot] = UInt16(next)
                    used.append(slot)
                    if next == 1 << size && size < 12 { size += 1 }
                    next += 1
                } else {  // table full: start over
                    put(clear)
                    reset()
                    next = end + 1
                    size = minimumCodeSize + 1
                }
                prefix = k
            }
        }
        put(prefix)
        put(end)
        if count > 0 { codes.append(UInt8(truncatingIfNeeded: buffer)) }
        reset()

        block.append(UInt8(minimumCodeSize))
        var p = 0
        while p < codes.count {
            let n = min(255, codes.count - p)
            block.append(UInt8(n))
            block += codes[p ..< p + n]
            p += n
        }
        block.append(0)
    }
}
