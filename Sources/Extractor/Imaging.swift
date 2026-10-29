import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let gateDeltaE = 12.0
let marginDeltaE = 1.5
let legendWarnDeltaE = 10.0
let minSolidity = 0.85
let minColorCover = 0.4

enum ExtractError: Error { case unreadable(URL), noLegend }

struct Lab { var l, a, b: Double }

func lab(_ c: (UInt8, UInt8, UInt8)) -> Lab {
    func lin(_ v: UInt8) -> Double {
        let s = Double(v) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    let (r, g, b) = (lin(c.0), lin(c.1), lin(c.2))
    let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
    let (fx, fy, fz) = (f(x), f(y), f(z))
    return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
}

func distance(_ p: Lab, _ q: Lab) -> Double {
    sqrt(pow(p.l - q.l, 2) + pow(p.a - q.a, 2) + pow(p.b - q.b, 2))
}

struct Pixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2])
    }
}

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw ExtractError.unreadable(url) }
    return image
}

func savePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func pixels(of image: CGImage) -> Pixels {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Pixels(width: w, height: h, rgba: data)
}

func morph(_ src: [Bool], w: Int, h: Int, rx: Int, ry: Int, erode: Bool) -> [Bool] {
    func pass(_ a: [Bool], lines: Int, length: Int, r: Int, step: Int, lineStep: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: a.count)
        var prefix = [Int32](repeating: 0, count: length + 1)
        for line in 0..<lines {
            let base = line * lineStep
            for i in 0..<length { prefix[i + 1] = prefix[i] + (a[base + i * step] ? 1 : 0) }
            for i in 0..<length {
                if erode {
                    guard i - r >= 0, i + r < length else { continue }
                    if prefix[i + r + 1] - prefix[i - r] == Int32(2 * r + 1) { out[base + i * step] = true }
                } else {
                    let lo = max(0, i - r), hi = min(length - 1, i + r)
                    if prefix[hi + 1] - prefix[lo] > 0 { out[base + i * step] = true }
                }
            }
        }
        return out
    }
    let rows = pass(src, lines: h, length: w, r: rx, step: 1, lineStep: w)
    return pass(rows, lines: w, length: h, r: ry, step: w, lineStep: 1)
}

func longRuns(_ m: [Bool], w: Int, h: Int, minLen: Int, horizontal: Bool) -> [Bool] {
    var out = [Bool](repeating: false, count: m.count)
    let lines = horizontal ? h : w
    let length = horizontal ? w : h
    let step = horizontal ? 1 : w
    let lineStep = horizontal ? w : 1
    for line in 0..<lines {
        let base = line * lineStep
        var run = 0
        for i in 0...length {
            if i < length, m[base + i * step] { run += 1; continue }
            if run >= minLen { for j in (i - run)..<i { out[base + j * step] = true } }
            run = 0
        }
    }
    return out
}

func pairs(_ m: [Bool], ink: [Bool], w: Int, h: Int, dmin: Int, dmax: Int, horizontal: Bool) -> [Bool] {
    var keep = [Bool](repeating: false, count: m.count)
    let step = horizontal ? w : 1
    let limit = horizontal ? h : w
    for i in 0..<m.count where m[i] {
        let pos = horizontal ? i / w : i % w
        search: for d in dmin...dmax {
            for sign in stride(from: -1, through: 1, by: 2) {
                let p = pos + sign * d
                guard p >= 0, p < limit else { continue }
                let partner = i + sign * d * step
                let mid = i + sign * (d / 2) * step
                if m[partner], !ink[mid] { keep[i] = true; break search }
            }
        }
    }
    let grown = horizontal
        ? morph(keep, w: w, h: h, rx: 0, ry: dmax, erode: false)
        : morph(keep, w: w, h: h, rx: dmax, ry: 0, erode: false)
    var out = keep
    for i in 0..<m.count where grown[i] && m[i] { out[i] = true }
    return out
}

struct Region {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var pixels: [Int]
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var area: Int { pixels.count }
    var fill: Double { Double(pixels.count) / Double(width * height) }
}

func components(_ mask: [Bool], w: Int, h: Int, eight: Bool) -> [Region] {
    var seen = [Bool](repeating: false, count: mask.count)
    var stack: [Int] = []
    var found: [Region] = []
    func push(_ j: Int) {
        if mask[j], !seen[j] { seen[j] = true; stack.append(j) }
    }
    for start in 0..<mask.count where mask[start] && !seen[start] {
        seen[start] = true
        stack.append(start)
        var reg = Region(minX: w, minY: h, maxX: 0, maxY: 0, pixels: [])
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            reg.pixels.append(i)
            reg.minX = min(reg.minX, x); reg.maxX = max(reg.maxX, x)
            reg.minY = min(reg.minY, y); reg.maxY = max(reg.maxY, y)
            if x > 0 { push(i - 1) }
            if x < w - 1 { push(i + 1) }
            if y > 0 { push(i - w) }
            if y < h - 1 { push(i + w) }
            if eight {
                if x > 0, y > 0 { push(i - w - 1) }
                if x < w - 1, y > 0 { push(i - w + 1) }
                if x > 0, y < h - 1 { push(i + w - 1) }
                if x < w - 1, y < h - 1 { push(i + w + 1) }
            }
        }
        found.append(reg)
    }
    return found
}

// Leave large enclosures and thin inter-tile seams open so hole filling closes only glyph interiors.
func fillHoles(_ mask: [Bool], w: Int, h: Int, maxHole: Int, seamLength: Int) -> [Bool] {
    var out = mask
    var seen = [Bool](repeating: false, count: mask.count)
    var stack: [Int] = []
    for start in 0..<mask.count where !mask[start] && !seen[start] {
        seen[start] = true
        stack.append(start)
        var hole: [Int] = []
        var open = false
        var x0 = w, x1 = 0, y0 = h, y1 = 0
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { open = true }
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            if hole.count <= maxHole { hole.append(i) }
            if x > 0, !mask[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
            if x < w - 1, !mask[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
            if y > 0, !mask[i - w], !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
            if y < h - 1, !mask[i + w], !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
        }
        let thin = min(x1 - x0, y1 - y0) + 1 <= 2 && max(x1 - x0, y1 - y0) + 1 >= seamLength
        if !open, hole.count <= maxHole, !thin { for i in hole { out[i] = true } }
    }
    return out
}

func convexHull(_ pixels: [Int], w: Int, minY: Int, height: Int) -> [(Double, Double)] {
    var lo = [Int](repeating: Int.max, count: height), hi = [Int](repeating: -1, count: height)
    for i in pixels {
        let row = i / w - minY
        lo[row] = min(lo[row], i % w); hi[row] = max(hi[row], i % w)
    }
    var points: [(Double, Double)] = []
    for row in 0..<height where hi[row] >= 0 {
        let y = Double(minY + row)
        for x in [Double(lo[row]) - 0.5, Double(hi[row]) + 0.5] {
            points.append((x, y - 0.5)); points.append((x, y + 0.5))
        }
    }
    points.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
        (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
    }
    var hull: [(Double, Double)] = []
    for p in points {
        while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
        hull.append(p)
    }
    let lowerCount = hull.count + 1
    for p in points.reversed().dropFirst() {
        while hull.count >= lowerCount, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
        hull.append(p)
    }
    hull.removeLast()
    return hull
}

func polygonArea(_ poly: [(Double, Double)]) -> Double {
    var twice = 0.0
    for i in poly.indices {
        let a = poly[i], b = poly[(i + 1) % poly.count]
        twice += a.0 * b.1 - b.0 * a.1
    }
    return abs(twice) / 2
}

func solidity(_ reg: Region, w: Int) -> Double {
    let hullArea = polygonArea(convexHull(reg.pixels, w: w, minY: reg.minY, height: reg.height))
    return hullArea > 0 ? Double(reg.area) / hullArea : 0
}

func simplify(_ poly: [(Double, Double)], epsilon: Double) -> [(Double, Double)] {
    guard poly.count > 3 else { return poly }
    func offset(_ p: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len = (dx * dx + dy * dy).squareRoot()
        if len == 0 { return ((p.0 - a.0) * (p.0 - a.0) + (p.1 - a.1) * (p.1 - a.1)).squareRoot() }
        return abs(dx * (a.1 - p.1) - (a.0 - p.0) * dy) / len
    }
    func keep(_ pts: [(Double, Double)]) -> [(Double, Double)] {
        guard pts.count > 2 else { return Array(pts.dropLast()) }
        var far = 0, farOffset = 0.0
        for i in 1..<(pts.count - 1) {
            let d = offset(pts[i], pts[0], pts[pts.count - 1])
            if d > farOffset { far = i; farOffset = d }
        }
        if farOffset <= epsilon { return [pts[0]] }
        return keep(Array(pts[...far])) + keep(Array(pts[far...]))
    }
    let half = poly.indices.max { offset(poly[$0], poly[0], poly[0]) < offset(poly[$1], poly[0], poly[0]) }!
    return keep(Array(poly[...half])) + keep(Array(poly[half...]) + [poly[0]])
}

func fillRect(_ mask: inout [Bool], _ r: CGRect, w: Int, h: Int, value: Bool) {
    let x0 = max(0, Int(r.minX.rounded(.down))), x1 = min(w - 1, Int(r.maxX.rounded(.up)))
    let y0 = max(0, Int(r.minY.rounded(.down))), y1 = min(h - 1, Int(r.maxY.rounded(.up)))
    guard x0 <= x1, y0 <= y1 else { return }
    for y in y0...y1 { for x in x0...x1 { mask[y * w + x] = value } }
}

func pointInPolygon(_ pt: CGPoint, _ poly: [[Int]]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let xi = Double(poly[i][0]), yi = Double(poly[i][1])
        let xj = Double(poly[j][0]), yj = Double(poly[j][1])
        let py = Double(pt.y), px = Double(pt.x)
        if ((yi > py) != (yj > py)), px < (xj - xi) * (py - yi) / (yj - yi) + xi {
            inside.toggle()
        }
        j = i
    }
    return inside
}

func boxIoU(_ a: [Int], _ b: [Int]) -> Double {
    let w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    let h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    guard w > 0, h > 0 else { return 0 }
    let inter = Double(w * h)
    return inter / (Double(a[2] * a[3] + b[2] * b[3]) - inter)
}
