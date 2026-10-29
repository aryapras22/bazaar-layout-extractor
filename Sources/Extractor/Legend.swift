import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct LegendClass {
    let name: String
    let rgb: (UInt8, UInt8, UInt8)
    let lab: Lab
}

func boothPrefix(_ name: String) -> String? {
    let t = name.lowercased()
    for prefix in ["large booth ", "booth "] where t.hasPrefix(prefix) {
        return String(t.dropFirst(prefix.count)).uppercased()
    }
    return nil
}

func isNearWhite(_ c: (UInt8, UInt8, UInt8)) -> Bool {
    (255 - Int(c.0)) + (255 - Int(c.1)) + (255 - Int(c.2)) < 30
}

// A legend swatch is a block of one colour that is bigger than a line and smaller than the page.
// Flood fill from a seed: a thin rule stays tiny, the page background runs into the image border.
func isSwatch(_ px: Pixels, seedX: Int, seedY: Int, textHeight: Int) -> Bool {
    let (w, h) = (px.width, px.height)
    let seed = lab(px.rgb(seedX, seedY))
    let maxArea = 100 * textHeight * textHeight
    var seen = Set<Int>([seedY * w + seedX])
    var stack = [seedY * w + seedX]
    var x0 = seedX, x1 = seedX, y0 = seedY, y1 = seedY
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        if x == 0 || y == 0 || x == w - 1 || y == h - 1 || seen.count > maxArea { return false }
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        for j in [i - 1, i + 1, i - w, i + w] where !seen.contains(j) {
            if distance(lab(px.rgb(j % w, j / w)), seed) < 6 { seen.insert(j); stack.append(j) }
        }
    }
    return min(x1 - x0, y1 - y0) + 1 >= textHeight / 2
}

func readLegend(_ image: CGImage) async throws -> [LegendClass] {
    let px = pixels(of: image)
    let size = CGSize(width: image.width, height: image.height)
    var classes: [LegendClass] = []
    var boxes: [CGRect] = []
    var wrapped: [(text: String, box: CGRect)] = []
    // The legend may sit on a tinted ground, so the most common colour counts as blank, not only white.
    var counts: [UInt32: Int] = [:]
    for i in stride(from: 0, to: px.width * px.height, by: 7) {
        counts[UInt32(px.rgba[i * 4] >> 3) << 16 | UInt32(px.rgba[i * 4 + 1] >> 3) << 8 | UInt32(px.rgba[i * 4 + 2] >> 3), default: 0] += 1
    }
    let ground = counts.max { $0.value < $1.value }?.key ?? 0x1F1F1F
    let groundLab = lab((UInt8(ground >> 16) << 3 | 4, UInt8((ground >> 8) & 31) << 3 | 4, UInt8(ground & 31) << 3 | 4))
    for observation in try await makeTextRequest().perform(on: image) {
        let name = foldLookalikes(observation.transcript)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
        guard !name.isEmpty,
              !classes.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { continue }
        let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        let y = Int(box.midY)
        guard y >= 0, y < px.height else { continue }
        var x = Int(box.minX) - 1
        while x > 8, isNearWhite(px.rgb(x, y)) || distance(lab(px.rgb(x, y)), groundLab) < 8 { x -= 1 }
        guard x > 8 else { continue }
        let color = px.rgb(x - 8, y)
        if isSwatch(px, seedX: x - 8, seedY: y, textHeight: max(1, Int(box.height))) {
            classes.append(LegendClass(name: name, rgb: color, lab: lab(color)))
            boxes.append(box)
        } else {
            wrapped.append((name, box))
        }
    }
    // A line with no swatch that sits just under an entry is that entry's second line. Anything else is a title.
    for line in wrapped.sorted(by: { $0.box.minY < $1.box.minY }) {
        let h = line.box.height
        guard let owner = boxes.indices.filter({
            let gap = line.box.minY - boxes[$0].maxY
            return gap > -h / 2 && gap < 1.2 * h
                && line.box.minX > boxes[$0].minX - h && line.box.minX < boxes[$0].minX + 3 * h
        }).max(by: { boxes[$0].maxY < boxes[$1].maxY }) else { continue }
        classes[owner] = LegendClass(name: classes[owner].name + " " + line.text, rgb: classes[owner].rgb, lab: classes[owner].lab)
        boxes[owner] = boxes[owner].union(line.box)
    }
    return classes
}

// A swatch printed in one colour can be drawn in another on the plan (print, screen, scan).
// A legend class that found no tiles takes the most common plan colour of similar hue
// that no other legend class already explains.
func adaptLegendToPlan(_ legend: [LegendClass], _ px: Pixels, classes only: [Int]) -> [LegendClass] {
    struct Cluster { var lab: Lab; var rgb: (UInt8, UInt8, UInt8); var count: Int }
    let stride = 2
    let scale = Double(max(px.width, px.height)) / 2000
    let minCount = 3 * Int(400 * scale * scale)
    var counts: [UInt32: Int] = [:]
    for i in Swift.stride(from: 0, to: px.width * px.height, by: stride) {
        counts[UInt32(px.rgba[i * 4]) << 16 | UInt32(px.rgba[i * 4 + 1]) << 8 | UInt32(px.rgba[i * 4 + 2]), default: 0] += stride
    }
    var clusters: [Cluster] = []
    for (key, count) in counts.sorted(by: { $0.value > $1.value }).prefix(5000) {
        let rgb = (UInt8(key >> 16), UInt8((key >> 8) & 255), UInt8(key & 255))
        let c = lab(rgb)
        if let j = clusters.firstIndex(where: { distance($0.lab, c) < 8 }) {
            clusters[j].count += count
        } else {
            clusters.append(Cluster(lab: c, rgb: rgb, count: count))
        }
    }
    func hue(_ l: Lab) -> Double { atan2(l.b, l.a) * 180 / .pi }
    func chroma(_ l: Lab) -> Double { sqrt(l.a * l.a + l.b * l.b) }
    var result = legend
    var taken = Set<Int>()
    for k in only {
        let want = legend[k].lab
        guard want.l > 15, want.l < 95, chroma(want) >= 15 else { continue }
        let candidates = clusters.indices.filter { j in
            let c = clusters[j]
            let gap = abs(hue(c.lab) - hue(want))
            return !taken.contains(j) && c.count >= minCount && c.lab.l > 15 && c.lab.l < 97 && chroma(c.lab) >= 15
                && min(gap, 360 - gap) <= 40 && distance(c.lab, want) <= 45
                && !legend.indices.contains { $0 != k && distance(c.lab, legend[$0].lab) < gateDeltaE }
        }
        // Edge blends sit nearer the swatch than the flat fill, so the most common colour wins, not the nearest.
        guard let j = candidates.max(by: { clusters[$0].count < clusters[$1].count }) else { continue }
        taken.insert(j)
        FileHandle.standardError.write(Data("note: \"\(legend[k].name)\" found no tiles, retrying with the nearest plan colour\n".utf8))
        result[k] = LegendClass(name: legend[k].name, rgb: clusters[j].rgb, lab: clusters[j].lab)
    }
    return result
}

func legendWarnings(_ classes: [LegendClass]) -> [String] {
    var out: [String] = []
    for i in 0..<classes.count {
        if classes[i].lab.l > 95 { out.append("\"\(classes[i].name)\" is nearly white, so it can merge with the background") }
        if classes[i].lab.l < 8 { out.append("\"\(classes[i].name)\" is nearly black, so it can merge with outlines and text") }
        for j in (i + 1)..<max(i + 1, classes.count) {
            let d = distance(classes[i].lab, classes[j].lab)
            if d < legendWarnDeltaE {
                out.append("\"\(classes[i].name)\" and \"\(classes[j].name)\" are only \(String(format: "%.1f", d)) apart in color, matches between them are flagged")
            }
        }
    }
    return out
}

func classify(_ px: Pixels, legend: [LegendClass]) -> [Int16] {
    var cache: [UInt32: Int16] = [:]
    var grid = [Int16](repeating: -1, count: px.width * px.height)
    for i in 0..<grid.count {
        let (r, g, b) = (px.rgba[i * 4], px.rgba[i * 4 + 1], px.rgba[i * 4 + 2])
        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        if let hit = cache[key] { grid[i] = hit; continue }
        let p = lab((r, g, b))
        var best: Int16 = -1
        var bestDistance = gateDeltaE
        for (j, entry) in legend.enumerated() {
            let d = distance(p, entry.lab)
            if d < bestDistance { bestDistance = d; best = Int16(j) }
        }
        cache[key] = best
        grid[i] = best
    }
    return grid
}

func medianRGB(_ px: Pixels, _ indices: [Int]) -> (UInt8, UInt8, UInt8) {
    let step = max(1, indices.count / 2000)
    var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
    for k in stride(from: 0, to: indices.count, by: step) {
        let i = indices[k]
        rs.append(px.rgba[i * 4]); gs.append(px.rgba[i * 4 + 1]); bs.append(px.rgba[i * 4 + 2])
    }
    rs.sort(); gs.sort(); bs.sort()
    return (rs[rs.count / 2], gs[gs.count / 2], bs[bs.count / 2])
}

func tilePolygon(_ reg: Region, rect: CGRect, faces: [Region], faceOf: [Int32], w: Int, epsilon: Double) -> [[Int]]? {
    var votes: [Int32: Int] = [:]
    for i in reg.pixels where faceOf[i] >= 0 { votes[faceOf[i], default: 0] += 1 }
    guard let best = votes.max(by: { $0.value < $1.value })?.key else { return nil }
    let face = faces[Int(best)]
    let bounds = CGRect(x: face.minX, y: face.minY, width: face.width, height: face.height)
    guard rect.insetBy(dx: -6, dy: -6).contains(bounds) else { return nil }
    let poly = simplify(convexHull(face.pixels, w: w, minY: face.minY, height: face.height), epsilon: epsilon)
    return poly.count >= 3 ? poly.map { [Int($0.0.rounded()), Int($0.1.rounded())] } : nil
}
