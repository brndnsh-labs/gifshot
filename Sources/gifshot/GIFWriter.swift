import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Streams an animated GIF to disk as frames arrive.
///
/// ImageIO's GIF encoder holds every frame until `CGImageDestinationFinalize`, then needs ~2x the raw
/// pixel size of all of them at once (gigabytes for a 60 s recording). So frames are encoded with
/// ImageIO in small batches and each batch's image blocks are spliced into one file. Every batch
/// starts by re-encoding the previous batch's last frame, which is then dropped, so the batch's first
/// real frame is still stored as a small diff (ImageIO crops unchanged pixels to transparency).
///
/// Not thread-safe: use from one serial queue.
nonisolated final class GIFWriter {
    static let batchSize = 10

    private let file: FileHandle
    private let maxFrames: Int
    private var pending: (image: CGImage, time: Double)?  // waiting for the next timestamp
    private var batch: [(image: CGImage, centiseconds: Int)] = []
    private var carry: CGImage?  // last frame already written, used as the next batch's reference
    private var origin: Double?
    private var elapsedCentiseconds = 0
    private var wroteHeader = false
    private var finished = false
    private(set) var frameCount = 0

    init(url: URL, maxFrames: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
        self.maxFrames = maxFrames
    }

    /// Adds a frame captured at `time` (seconds, any monotonic clock). A frame's delay is the time
    /// until the next one, so dropped or skipped frames don't speed up playback.
    func add(_ image: CGImage, at time: Double) {
        guard !finished, frameCount + batch.count < maxFrames else { return }
        if let pending { enqueue(pending.image, from: pending.time, to: time) }
        pending = (image, time)
    }

    /// Writes the last frame (shown until `time`) and closes the file. Returns false if no frames
    /// were written.
    func finish(at time: Double) -> Bool {
        guard !finished else { return false }
        finished = true
        if let pending {
            let shown = time - pending.time
            enqueue(pending.image, from: pending.time, to: pending.time + (shown > 0 && shown < 120 ? shown : 1.0 / 15))
        }
        flush()
        if wroteHeader { file.write(Data([0x3B])) }  // trailer
        try? file.close()
        return wroteHeader
    }

    private func enqueue(_ image: CGImage, from start: Double, to end: Double) {
        // Round on the running total so per-frame rounding error never accumulates.
        let origin = self.origin ?? start
        self.origin = origin
        let endCentiseconds = Int(((end - origin) * 100).rounded())
        let delay = max(2, endCentiseconds - elapsedCentiseconds)  // < 2 cs gets clamped by viewers
        elapsedCentiseconds += delay
        batch.append((image, delay))
        if batch.count == Self.batchSize { flush() }
    }

    private func flush() {
        guard let last = batch.last?.image else { return }
        let images = (carry.map { [$0] } ?? []) + batch.map(\.image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString,
                                                                 images.count, nil) else { return }
        for image in images { CGImageDestinationAddImage(destination, image, nil) }
        if CGImageDestinationFinalize(destination) {
            splice(Array(data as Data), skipFirst: carry != nil, delays: batch.map(\.centiseconds))
            frameCount += batch.count
            carry = last
        } else {
            NSLog("gifshot: failed to encode \(batch.count) frames")
        }
        batch.removeAll()
    }

    /// Copies a batch GIF's frames into the output file. The batch's global color table becomes a
    /// local table on each frame, since every batch has its own palette.
    private func splice(_ gif: [UInt8], skipFirst: Bool, delays: [Int]) {
        guard gif.count > 13 else { return }
        let screenFlags = gif[10]
        let globalTableSize = screenFlags & 0x80 != 0 ? 3 << (Int(screenFlags & 0x07) + 1) : 0
        let globalTable = gif[13 ..< 13 + globalTableSize]
        if !wroteHeader {
            var header = Array("GIF89a".utf8) + gif[6 ..< 10]  // canvas width, height
            header += [0x70, 0, 0]  // no global color table
            header += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]  // loop forever
            file.write(Data(header))
            wroteHeader = true
        }

        var out: [UInt8] = []
        var control: [UInt8]?
        var index = skipFirst ? -1 : 0  // frame index into `delays`; -1 is the dropped reference frame
        var p = 13 + globalTableSize
        while p < gif.count {
            switch gif[p] {
            case 0x21:  // extension; keep only graphic control, which belongs to the next image
                let end = Self.endOfSubBlocks(gif, from: p + 2)
                if gif[p + 1] == 0xF9 { control = Array(gif[p ..< end]) }
                p = end
            case 0x2C:  // image descriptor, optional local color table, LZW data
                var descriptor = Array(gif[p ..< p + 10])
                var q = p + 10
                var table = globalTable
                if descriptor[9] & 0x80 != 0 {
                    let size = 3 << (Int(descriptor[9] & 0x07) + 1)
                    table = gif[q ..< q + size]
                    q += size
                } else {
                    descriptor[9] = (descriptor[9] & 0x78) | 0x80 | (screenFlags & 0x07)
                }
                let end = Self.endOfSubBlocks(gif, from: q + 1)
                if index >= 0, index < delays.count {
                    var gce = control ?? [0x21, 0xF9, 0x04, 0x04, 0, 0, 0, 0]  // leave in place, no transparency
                    gce[4] = UInt8(delays[index] & 0xFF)
                    gce[5] = UInt8(delays[index] >> 8)
                    out += gce + descriptor + table + gif[q ..< end]
                }
                index += 1
                control = nil
                p = end
            default:  // trailer
                p = gif.count
            }
        }
        file.write(Data(out))
    }

    private static func endOfSubBlocks(_ bytes: [UInt8], from start: Int) -> Int {
        var p = start
        while p < bytes.count, bytes[p] != 0 { p += Int(bytes[p]) + 1 }
        return min(p + 1, bytes.count)
    }
}
