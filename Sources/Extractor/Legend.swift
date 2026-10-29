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
    swatchBounds(px, seedX: seedX, seedY: seedY, textHeight: textHeight) != nil
}

func swatchBounds(_ px: Pixels, seedX: Int, seedY: Int, textHeight: Int) -> CGRect? {
    let (w, h) = (px.width, px.height)
    let seed = lab(px.rgb(seedX, seedY))
    let maxArea = 100 * textHeight * textHeight
    var seen = Set<Int>([seedY * w + seedX])
    var stack = [seedY * w + seedX]
    var x0 = seedX, x1 = seedX, y0 = seedY, y1 = seedY
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        if x == 0 || y == 0 || x == w - 1 || y == h - 1 || seen.count > maxArea { return nil }
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        for j in [i - 1, i + 1, i - w, i + w] where !seen.contains(j) {
            if distance(lab(px.rgb(j % w, j / w)), seed) < 6 { seen.insert(j); stack.append(j) }
        }
    }
    guard min(x1 - x0, y1 - y0) + 1 >= textHeight / 2 else { return nil }
    return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
}

/// Seeds to try for a swatch whose usual place, just left of the text, held none. JPEG ringing can put that guess
/// on the swatch's dark border, and a swatch the recogniser read as a glyph sits inside the text box instead.
/// A swatch another entry already has is skipped, so the lines of a wrapped entry do not take its swatch, and so is
/// a blank or near-black block, which is the inside of a framed word such as ENTRANCE or a bold glyph. The search stays within two text heights,
/// because further out it reaches icons of other entries.
func swatchBeside(
    _ px: Pixels, firstGuess: Int, textBox: CGRect, y: Int, textHeight: Int, claimed: [CGRect], ground: Lab
) -> (seed: Int, bounds: CGRect)? {
    let left = Array(stride(from: firstGuess, to: max(0, firstGuess - 2 * textHeight), by: -4))
    let inside = Array(stride(from: Int(textBox.minX) + 4, to: Int(textBox.minX) + 3 * textHeight, by: 4))
    for seed in left + inside where seed > 0 && seed < px.width {
        guard !isBlank(px, seed, y, ground), lab(px.rgb(seed, y)).l > 30,
              !claimed.contains(where: { $0.contains(CGPoint(x: seed, y: y)) }),
              let bounds = swatchBounds(px, seedX: seed, seedY: y, textHeight: textHeight) else { continue }
        return (seed, bounds)
    }
    return nil
}

func isBlank(_ px: Pixels, _ x: Int, _ y: Int, _ ground: Lab) -> Bool {
    isNearWhite(px.rgb(x, y)) || distance(lab(px.rgb(x, y)), ground) < 8
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
    // Entries whose swatch is not where it usually is wait for a second pass, so that the swatch of an entry
    // that found it at once is known by then.
    struct Entry { let order: Int; let name: String; let box: CGRect; let y: Int; let firstGuess: Int }
    var found: [(order: Int, color: (UInt8, UInt8, UInt8), name: String, box: CGRect)] = []
    var retry: [Entry] = []
    var claimed: [CGRect] = []
    for (order, observation) in try await makeTextRequest().perform(on: image).enumerated() {
        // A swatch the recogniser read as a glyph leaves a stray symbol at the start of the name.
        let name = String(foldLookalikes(observation.transcript)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
            .drop { !$0.isLetter && !$0.isNumber })
        guard !name.isEmpty,
              !found.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { continue }
        let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        let y = Int(box.midY)
        guard y >= 0, y < px.height else { continue }
        var x = Int(box.minX) - 1
        // Blur or JPEG ringing leaves a halo of grey just outside the glyphs, which is not the ground.
        var halo = max(1, Int(box.height) / 6)
        while x > 8, halo > 0, !isBlank(px, x, y, groundLab) { x -= 1; halo -= 1 }
        while x > 8, isBlank(px, x, y, groundLab) { x -= 1 }
        guard x > 8 else { continue }
        if let bounds = swatchBounds(px, seedX: x - 8, seedY: y, textHeight: max(1, Int(box.height))) {
            found.append((order, px.rgb(x - 8, y), name, box))
            claimed.append(bounds)
        } else {
            retry.append(Entry(order: order, name: name, box: box, y: y, firstGuess: x - 8))
        }
    }
    for entry in retry where !found.contains(where: { $0.name.lowercased() == entry.name.lowercased() }) {
        let textHeight = max(1, Int(entry.box.height))
        if let (seed, bounds) = swatchBeside(
            px, firstGuess: entry.firstGuess, textBox: entry.box, y: entry.y, textHeight: textHeight, claimed: claimed, ground: groundLab) {
            found.append((entry.order, px.rgb(seed, entry.y), entry.name, entry.box))
            claimed.append(bounds)
        } else {
            wrapped.append((entry.name, entry.box))
        }
    }
    for entry in found.sorted(by: { $0.order < $1.order }) {
        classes.append(LegendClass(name: entry.name, rgb: entry.color, lab: lab(entry.color)))
        boxes.append(entry.box)
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
    let scale = Double(px.page) / 2000
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
    let eligible = only.filter { k in
        let want = legend[k].lab
        return want.l > 15 && want.l < 95 && chroma(want) >= 15
    }
    var pending = eligible
    func preferred(_ k: Int) -> Int? {
        let want = legend[k].lab
        let matched = clusters.filter { distance($0.lab, want) < gateDeltaE }.reduce(0) { $0 + $1.count }
        return clusters.indices.filter { j in
            let c = clusters[j]
            let gap = abs(hue(c.lab) - hue(want))
            return !taken.contains(j) && c.count >= max(minCount, 4 * matched) && c.lab.l > 15 && c.lab.l < 97 && chroma(c.lab) >= 15
                && min(gap, 360 - gap) <= 40 && distance(c.lab, want) <= 45
                && !legend.indices.contains { $0 != k && distance(c.lab, legend[$0].lab) < gateDeltaE }
        }.max { clusters[$0].count < clusters[$1].count }
    }
    // Two classes can prefer the same colour (faded orange and yellow); the nearer swatch gets it and the other
    // takes its next choice, so a uniform shift of all colours does not swap classes.
    while !pending.isEmpty {
        var wanted: [Int: [Int]] = [:]
        for k in pending { if let j = preferred(k) { wanted[j, default: []].append(k) } }
        if wanted.isEmpty { break }
        for j in wanted.keys.sorted() {
            guard let k = wanted[j]?.min(by: { distance(clusters[j].lab, legend[$0].lab) < distance(clusters[j].lab, legend[$1].lab) }) else { continue }
            taken.insert(j)
            pending.removeAll { $0 == k }
            FileHandle.standardError.write(Data("note: \"\(legend[k].name)\" found few tiles, retrying with the nearest plan colour\n".utf8))
            result[k] = LegendClass(name: legend[k].name, rgb: clusters[j].rgb, lab: clusters[j].lab)
        }
    }
    // Fading or a screen shifts every colour a little, and a tile shaded around its mean then reaches past the gate on
    // one side. A class keeps its swatch unless the plan's own most common colour nearby is clearly off it.
    for k in eligible where result[k].lab.l == legend[k].lab.l && result[k].lab.a == legend[k].lab.a {
        let want = legend[k].lab
        let nearest = { (c: Lab) in legend.indices.min { distance(c, legend[$0].lab) < distance(c, legend[$1].lab) } }
        let mode = clusters.indices.filter { j in
            let d = distance(clusters[j].lab, want)
            return !taken.contains(j) && d <= 2 * gateDeltaE && nearest(clusters[j].lab) == k && clusters[j].count >= minCount
        }.max { clusters[$0].count < clusters[$1].count }
        guard let j = mode, distance(clusters[j].lab, want) > gateDeltaE / 2 else { continue }
        result[k] = LegendClass(name: legend[k].name, rgb: clusters[j].rgb, lab: clusters[j].lab)
    }
    return applyFadeToAchromatic(legend, to: result)
}

/// Fading maps every colour c to a*c + b. The classes that moved onto plan colours show a and b, and black and grey
/// swatches, which the colour search skips because dark and grey pixels are mostly text, take the faded value. A plan
/// whose classes did not move by a clear fade is left alone.
func applyFadeToAchromatic(_ legend: [LegendClass], to result: [LegendClass]) -> [LegendClass] {
    func channels(_ c: (UInt8, UInt8, UInt8)) -> [Double] { [Double(c.0), Double(c.1), Double(c.2)] }
    let moved = legend.indices.filter { distance(legend[$0].lab, result[$0].lab) > 4 }
    guard moved.count >= 2 else { return result }
    var pairs: [(from: Double, to: Double)] = []
    for k in moved { pairs += zip(channels(legend[k].rgb), channels(result[k].rgb)).map { (from: $0, to: $1) } }
    let n = Double(pairs.count)
    let sx = pairs.reduce(0.0) { $0 + $1.from }, sy = pairs.reduce(0.0) { $0 + $1.to }
    let sxx = pairs.reduce(0.0) { $0 + $1.from * $1.from }, sxy = pairs.reduce(0.0) { $0 + $1.from * $1.to }
    let spread = n * sxx - sx * sx
    guard spread > 0 else { return result }
    let gain = (n * sxy - sx * sy) / spread, offset = (sy - gain * sx) / n
    let squares = pairs.reduce(0.0) { total, pair in
        let miss = gain * pair.from + offset - pair.to
        return total + miss * miss
    }
    guard (0.5...0.95).contains(gain), offset > 10, (squares / n).squareRoot() < 15 else { return result }
    var faded = result
    for k in legend.indices where !moved.contains(k) && !isNearWhite(legend[k].rgb) {
        let c = legend[k].lab
        guard (c.a * c.a + c.b * c.b).squareRoot() < 15 else { continue }
        let v = channels(legend[k].rgb).map { UInt8(max(0, min(255, (gain * $0 + offset).rounded()))) }
        faded[k] = LegendClass(name: legend[k].name, rgb: (v[0], v[1], v[2]), lab: lab((v[0], v[1], v[2])))
    }
    return faded
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
    // A dark tile has only its white text as faces, and a glyph is not the tile's outline.
    guard 2 * face.area >= reg.area else { return nil }
    let bounds = CGRect(x: face.minX, y: face.minY, width: face.width, height: face.height)
    guard rect.insetBy(dx: -6, dy: -6).contains(bounds) else { return nil }
    let poly = simplify(convexHull(face.pixels, w: w, minY: face.minY, height: face.height), epsilon: epsilon)
    return poly.count >= 3 ? poly.map { [Int($0.0.rounded()), Int($0.1.rounded())] } : nil
}
