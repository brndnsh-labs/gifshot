import Foundation

/// BGRA pixels (one `UInt32` per pixel, `0xAARRGGBB`) with a row stride, e.g. a locked `CVPixelBuffer`.
nonisolated struct Pixels {
    let base: UnsafeRawPointer
    let bytesPerRow: Int

    @inline(__always) func row(_ y: Int) -> UnsafePointer<UInt32> {
        (base + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
    }
}

/// Inclusive pixel rectangle.
nonisolated struct Box {
    var left, top, right, bottom: Int
    var width: Int { right - left + 1 }
    var height: Int { bottom - top + 1 }
}

/// Chooses each frame's colors and maps its changed pixels to palette indices.
///
/// A diff with at most 255 distinct colors (the usual case for UI and text) is stored exactly.
/// Otherwise colors are quantized with median cut on a 6-bit-per-channel histogram plus one k-means
/// pass. That palette is reused for up to `reuseFrames` frames while a sample shows it still fits,
/// because more pixels then map to the color already on screen and can be left transparent.
///
/// Not thread-safe: owned by one `GIFWriter`.
nonisolated final class Palette {
    static let maxColors = 255  // the 256th index is transparency
    static let reuseFrames = 10

    private static let emptyKey = UInt32.max
    private var exactKeys = [UInt32](repeating: emptyKey, count: 1024)
    private var exactValues = [UInt8](repeating: 0, count: 1024)

    private static let bins = 1 << 18
    private let binCount = UnsafeMutablePointer<UInt32>.allocate(capacity: bins)
    private let binSum = UnsafeMutablePointer<UInt32>.allocate(capacity: bins * 3)
    private let nearestCache = UnsafeMutablePointer<UInt16>.allocate(capacity: bins)  // 0xFFFF = not cached
    private var cachedBins: [Int] = []
    private var quantized: [UInt32] = []
    private var age = 0
    private var baseError = -1.0

    init() {
        binCount.initialize(repeating: 0, count: Self.bins)
        binSum.initialize(repeating: 0, count: Self.bins * 3)
        nearestCache.initialize(repeating: 0xFFFF, count: Self.bins)
    }

    deinit {
        binCount.deallocate()
        binSum.deallocate()
        nearestCache.deallocate()
    }

    /// On entry `indices` is 1 for pixels in `box` that need updating, 0 for ones to leave as shown.
    /// On return it holds palette indices, with `colors.count` meaning transparent, and `shown` holds
    /// what a viewer will display.
    func map(_ src: Pixels, _ box: Box, indices: UnsafeMutablePointer<UInt8>,
             shown: UnsafeMutablePointer<UInt32>, stride: Int) -> (colors: [UInt32], transparent: Bool) {
        if let colors = exactColors(src, box, indices, stride) {
            let clear = UInt8(colors.count)
            var transparent = false
            var lastColor = Self.emptyKey, lastIndex: UInt8 = 0
            for y in box.top ... box.bottom {
                let s = src.row(y), m = indices + y * stride, v = shown + y * stride
                for x in box.left ... box.right {
                    guard m[x] == 1 else { m[x] = clear; transparent = true; continue }
                    let c = s[x] & 0xFFFFFF
                    if c != lastColor { lastColor = c; lastIndex = exactValues[slot(of: c)] }
                    m[x] = lastIndex
                    v[x] = c
                }
            }
            return (colors, transparent)
        }

        if quantized.isEmpty || age >= Self.reuseFrames
            || sampleError(src, box, indices, stride) > max(baseError, 1) * 1.5 + 4 {
            rebuild(src, box, indices, stride)
        }
        age += 1
        let clear = UInt8(quantized.count)
        var transparent = false, error = 0, count = 0
        for y in box.top ... box.bottom {
            let s = src.row(y), m = indices + y * stride, v = shown + y * stride
            for x in box.left ... box.right {
                guard m[x] == 1 else { m[x] = clear; transparent = true; continue }
                let i = nearest(s[x])
                let q = quantized[i]
                error += Self.distance(s[x], q)
                count += 1
                if q == v[x] {  // quantizes to what's already shown
                    m[x] = clear
                    transparent = true
                } else {
                    m[x] = UInt8(i)
                    v[x] = q
                }
            }
        }
        if baseError < 0 { baseError = Double(error) / Double(max(count, 1)) }
        return (quantized, transparent)
    }

    // MARK: Exact

    /// The distinct colors of the pixels to update, or nil if there are more than `maxColors`.
    private func exactColors(_ src: Pixels, _ box: Box, _ indices: UnsafeMutablePointer<UInt8>,
                             _ stride: Int) -> [UInt32]? {
        for i in exactKeys.indices { exactKeys[i] = Self.emptyKey }
        var colors: [UInt32] = []
        var lastColor = Self.emptyKey
        for y in box.top ... box.bottom {
            let s = src.row(y), m = indices + y * stride
            for x in box.left ... box.right where m[x] == 1 {
                let c = s[x] & 0xFFFFFF
                if c == lastColor { continue }
                lastColor = c
                let i = slot(of: c)
                if exactKeys[i] == Self.emptyKey {
                    if colors.count == Self.maxColors { return nil }
                    exactKeys[i] = c
                    exactValues[i] = UInt8(colors.count)
                    colors.append(c)
                }
            }
        }
        return colors
    }

    /// Open-addressing slot for `color` in the exact table: its own entry, or the empty one it goes in.
    @inline(__always) private func slot(of color: UInt32) -> Int {
        var i = Int((color &* 2_654_435_761) >> 22)
        while exactKeys[i] != color && exactKeys[i] != Self.emptyKey { i = (i + 1) & 1023 }
        return i
    }

    // MARK: Quantized

    @inline(__always) private static func bin(_ c: UInt32) -> Int {
        Int((c >> 18) & 0x3F) << 12 | Int((c >> 10) & 0x3F) << 6 | Int((c >> 2) & 0x3F)
    }

    @inline(__always) private static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        let r = Int((a >> 16) & 0xFF) - Int((b >> 16) & 0xFF)
        let g = Int((a >> 8) & 0xFF) - Int((b >> 8) & 0xFF)
        let b = Int(a & 0xFF) - Int(b & 0xFF)
        return r * r + g * g + b * b
    }

    /// Index of the quantized color nearest to `c`, cached per histogram bin.
    @inline(__always) private func nearest(_ c: UInt32) -> Int {
        let bin = Self.bin(c)
        if nearestCache[bin] != 0xFFFF { return Int(nearestCache[bin]) }
        let r = Int((c >> 16) & 0xFF), g = Int((c >> 8) & 0xFF), b = Int(c & 0xFF)
        var best = 0, bestDistance = Int.max
        for (i, q) in quantized.enumerated() {
            let dr = r - Int((q >> 16) & 0xFF), dg = g - Int((q >> 8) & 0xFF), db = b - Int(q & 0xFF)
            let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db  // rough perceptual weights
            if d < bestDistance { bestDistance = d; best = i }
        }
        nearestCache[bin] = UInt16(best)
        cachedBins.append(bin)
        return best
    }

    /// Mean squared error of the current palette on a sparse sample of the pixels to update.
    private func sampleError(_ src: Pixels, _ box: Box, _ indices: UnsafeMutablePointer<UInt8>,
                             _ stride: Int) -> Double {
        var error = 0, count = 0
        for y in Swift.stride(from: box.top, through: box.bottom, by: 3) {
            let s = src.row(y), m = indices + y * stride
            for x in Swift.stride(from: box.left + y % 7, through: box.right, by: 7) where m[x] == 1 {
                error += Self.distance(s[x], quantized[nearest(s[x])])
                count += 1
            }
        }
        return count == 0 ? 0 : Double(error) / Double(count)
    }

    private struct Entry { var r, g, b, weight: Float }

    /// Median cut over the histogram of the pixels to update, refined with one k-means pass.
    private func rebuild(_ src: Pixels, _ box: Box, _ indices: UnsafeMutablePointer<UInt8>, _ stride: Int) {
        var used: [Int] = []
        for y in box.top ... box.bottom {
            let s = src.row(y), m = indices + y * stride
            for x in box.left ... box.right where m[x] == 1 {
                let c = s[x], bin = Self.bin(c)
                if binCount[bin] == 0 { used.append(bin) }
                binCount[bin] += 1
                binSum[bin * 3] += (c >> 16) & 0xFF
                binSum[bin * 3 + 1] += (c >> 8) & 0xFF
                binSum[bin * 3 + 2] += c & 0xFF
            }
        }
        var entries = used.map { bin in
            let n = Float(binCount[bin])
            return Entry(r: Float(binSum[bin * 3]) / n, g: Float(binSum[bin * 3 + 1]) / n,
                         b: Float(binSum[bin * 3 + 2]) / n, weight: n)
        }
        for bin in used {
            binCount[bin] = 0
            binSum[bin * 3] = 0; binSum[bin * 3 + 1] = 0; binSum[bin * 3 + 2] = 0
        }

        // Repeatedly split the box with the largest (weighted) color range at its median.
        func widest(_ range: Range<Int>) -> (score: Float, axis: Int) {
            guard range.count > 1 else { return (0, 0) }
            var lo: (Float, Float, Float) = (255, 255, 255), hi: (Float, Float, Float) = (0, 0, 0)
            var weight: Float = 0
            for e in entries[range] {
                lo = (min(lo.0, e.r), min(lo.1, e.g), min(lo.2, e.b))
                hi = (max(hi.0, e.r), max(hi.1, e.g), max(hi.2, e.b))
                weight += e.weight
            }
            let spans = [(hi.0 - lo.0) * 1.0, (hi.1 - lo.1) * 1.2, (hi.2 - lo.2) * 0.8]  // rough luma weights
            let axis = spans.indices.max { spans[$0] < spans[$1] }!
            return (spans[axis] * weight.squareRoot(), axis)
        }
        var boxes = [0 ..< entries.count]
        var scores = [widest(boxes[0])]
        while boxes.count < Self.maxColors {
            guard let i = scores.indices.max(by: { scores[$0].score < scores[$1].score }),
                  scores[i].score > 0 else { break }
            let range = boxes[i], axis = scores[i].axis
            entries[range].sort { axis == 0 ? $0.r < $1.r : axis == 1 ? $0.g < $1.g : $0.b < $1.b }
            let half = entries[range].reduce(0) { $0 + $1.weight } / 2
            var total: Float = 0, split = range.upperBound - 1
            for j in range {
                total += entries[j].weight
                if total >= half { split = min(max(j + 1, range.lowerBound + 1), range.upperBound - 1); break }
            }
            boxes[i] = range.lowerBound ..< split
            boxes.append(split ..< range.upperBound)
            scores[i] = widest(boxes[i])
            scores.append(widest(boxes[boxes.count - 1]))
        }
        var centers = boxes.map { range in
            var sum = Entry(r: 0, g: 0, b: 0, weight: 0)
            for e in entries[range] {
                sum.r += e.r * e.weight; sum.g += e.g * e.weight; sum.b += e.b * e.weight; sum.weight += e.weight
            }
            return (sum.r / sum.weight, sum.g / sum.weight, sum.b / sum.weight)
        }

        // One k-means pass: move each color to the mean of the entries nearest to it.
        var sums = [Entry](repeating: Entry(r: 0, g: 0, b: 0, weight: 0), count: centers.count)
        for e in entries {
            var best = 0, bestDistance = Float.infinity
            for (k, c) in centers.enumerated() {
                let d = (e.r - c.0) * (e.r - c.0) + (e.g - c.1) * (e.g - c.1) + (e.b - c.2) * (e.b - c.2)
                if d < bestDistance { bestDistance = d; best = k }
            }
            sums[best].r += e.r * e.weight; sums[best].g += e.g * e.weight
            sums[best].b += e.b * e.weight; sums[best].weight += e.weight
        }
        for k in centers.indices where sums[k].weight > 0 {
            let w = sums[k].weight
            centers[k] = (sums[k].r / w, sums[k].g / w, sums[k].b / w)
        }

        quantized = centers.map { UInt32($0.0.rounded()) << 16 | UInt32($0.1.rounded()) << 8 | UInt32($0.2.rounded()) }
        for bin in cachedBins { nearestCache[bin] = 0xFFFF }
        cachedBins.removeAll(keepingCapacity: true)
        age = 0
        baseError = -1
    }
}
