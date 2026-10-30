import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct LegendLayerOutput {
    var items: [Item]
    var labelledClasses: Set<String>
    var colorReasons: [[String]]
    var scale: Double
}

func rebuildLabelledReasons(_ items: inout [Item], labelledClasses: Set<String>, colorReasons: [[String]]) {
    var counts: [String: Int] = [:]
    for item in items where labelledClasses.contains(item.cls) {
        if let id = item.id { counts[id, default: 0] += 1 }
    }
    for i in items.indices {
        var reasons = i < colorReasons.count ? colorReasons[i] : []
        if labelledClasses.contains(items[i].cls) {
            if let id = items[i].id {
                if counts[id, default: 0] > 1 { reasons.append("duplicate id") }
            } else if !items[i].text.isEmpty {
                reasons.append("text \"\(items[i].text)\" is not a readable id")
            } else {
                reasons.append("no label found")
            }
        }
        items[i].needsReview = !reasons.isEmpty
        items[i].reason = reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }
}

// Thresholds scale with the page, so a plan whose booths are small for its page (a scan with margins
// and a title block) would lose them all. The small tiles are the area-weighted 25th percentile of
// sqrt(area) over legend-coloured regions, so fragments such as text blobs are outvoted by real tiles
// and the smallest booths set the thresholds, not the typical one. The scale shrinks to fit them but
// never grows past the page scale.
let referenceTileSide = 25.0

/// Side in pixels of the small tiles: the area-weighted 25th percentile of sqrt(area), or nil with too few regions.
func smallTileSide(_ grid: [Int16], w: Int, h: Int, area: Int) -> Double? {
    let cap = max(2500, area / 200)
    let regions = components(grid.map { $0 >= 0 }, w: w, h: h, eight: false)
        .filter { $0.area >= 25 && $0.area <= cap }
        .map { (side: Double($0.area).squareRoot(), weight: $0.area) }
        .sorted { $0.side < $1.side }
    guard regions.count >= 8 else { return nil }
    let half = regions.reduce(0) { $0 + $1.weight }
    var seen = 0
    for region in regions {
        seen += region.weight
        if seen * 4 >= half { return region.side }
    }
    return nil
}

func tileScale(_ grid: [Int16], w: Int, h: Int, page pageSide: Int, area: Int) -> Double {
    let page = Double(pageSide) / 2000
    guard let side = smallTileSide(grid, w: w, h: h, area: area) else { return page }
    return min(page, side / referenceTileSide)
}

private func isColoured(_ entry: LegendClass) -> Bool { hypot(entry.lab.a, entry.lab.b) >= 15 }

func legendLayer(_ image: CGImage, _ px: Pixels, legend: [LegendClass]) async throws -> LegendLayerOutput {
    let (w, h) = (px.width, px.height)
    let canvas = CGRect(x: 0, y: 0, width: w, height: h)
    let grid = classify(px, legend: legend)
    let scale = tileScale(grid, w: w, h: h, page: px.page, area: px.area)
    let r = max(1, Int((3 * scale).rounded()))
    let minArea = Int(400 * scale * scale)
    let page = Double(px.page) / 2000
    let maxHole = Int(2000 * page * page)  // an upper bound, so it follows the page, not the smallest tile
    let seamLength = Int(20 * scale)
    let outlines = morph(darkPixels(px, below: 60), w: w, h: h, rx: 1, ry: 1, erode: false)
    let faces = components(outlines.map { !$0 }, w: w, h: h, eight: false)
    var faceOf = [Int32](repeating: -1, count: w * h)
    for (j, face) in faces.enumerated() { for i in face.pixels { faceOf[i] = Int32(j) } }

    struct Found {
        var item: Item
        let cls: Int
        let colorReasons: [String]
        let small: Bool
    }
    var found: [Found] = []
    struct Candidate {
        let cls: Int
        let region: Region
        let rect: CGRect
        let reasons: [String]
        let tileArea: Int
        let small: Bool
    }
    var candidates: [Candidate] = []

    for (k, entry) in legend.enumerated() {
        let whole = fillHoles(grid.map { $0 == Int16(k) }, w: w, h: h, maxHole: maxHole, seamLength: seamLength)
        let mask = morph(whole, w: w, h: h, rx: r, ry: r, erode: true)
        for reg in components(mask, w: w, h: h, eight: false) {
            // The mask was eroded by r, so the size test uses the restored box a tile of this size would have.
            // Tiles that only pass that way are kept later if their class turns out to carry IDs.
            guard (reg.width + 2 * r) * (reg.height + 2 * r) >= minArea, solidity(reg, w: w) >= minSolidity else { continue }
            let small = reg.area < Int(400 * page * page)
            let rect = CGRect(x: reg.minX - r, y: reg.minY - r, width: reg.width + 2 * r, height: reg.height + 2 * r)
                .intersection(canvas)
            var reasons: [String] = []

            let median = lab(medianRGB(px, reg.pixels))
            let ranked = legend.enumerated()
                .map { (index: $0.offset, d: distance(median, $0.element.lab)) }
                .sorted { $0.d < $1.d }
            if ranked.count > 1, ranked[1].d - ranked[0].d < marginDeltaE {
                reasons.append("color is nearly as close to \"\(legend[ranked[1].index].name)\"")
            }
            if ranked[0].index != k {
                reasons.append("median color is closer to \"\(legend[ranked[0].index].name)\"")
            }

            var tileArea = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) where grid[y * w + x] == Int16(k) { tileArea += 1 }
            }
            guard Double(tileArea) >= minColorCover * rect.width * rect.height else { continue }

            candidates.append(Candidate(cls: k, region: reg, rect: rect, reasons: reasons, tileArea: tileArea, small: small))
        }
    }

    // The booth size of the plan is the typical short side of a region, which a divider that vanished does not move.
    // The text and outline fragments of a faded black class can outnumber the booths, so the unit has a floor.
    let shortSides = candidates.map { Double(min($0.rect.width, $0.rect.height)) }.sorted()
    let unit = max(shortSides.isEmpty ? referenceTileSide : shortSides[shortSides.count / 2], 0.8 * referenceTileSide * page)
    for c in candidates {
        let entry = legend[c.cls]
        let raw = try await readLabel(image, in: c.rect)
        let label = raw.flatMap { cleanLabel($0) }
        let rgb = [Int(entry.rgb.0), Int(entry.rgb.1), Int(entry.rgb.2)]
        let polygon = tilePolygon(c.region, rect: c.rect, faces: faces, faceOf: faceOf, w: w, epsilon: 2 * scale)
        // A divider that faded or fell between pixels leaves several booths in one region.
        let slices = try await mergedTiles(image, c.rect, unit: unit)
        for part in slices ?? [(c.rect, raw, label)] {
            found.append(Found(
                item: Item(
                    cls: entry.name, box: box(part.rect), area: c.tileArea / (slices?.count ?? 1), fillRgb: rgb, legendRgb: rgb,
                    text: part.raw ?? "", id: part.label, needsReview: !c.reasons.isEmpty,
                    reason: c.reasons.isEmpty ? nil : c.reasons.joined(separator: "; "),
                    polygon: slices == nil ? polygon : nil),
                cls: c.cls, colorReasons: c.reasons, small: c.small))
        }
    }

    var labelledIndices = Set<Int>()
    for k in legend.indices {
        let members = found.filter { $0.cls == k }
        let withLabel = members.filter { $0.item.id != nil }.count
        if !members.isEmpty, withLabel * 2 >= members.count { labelledIndices.insert(k) }
    }
    // On a numbered plan a class that read few IDs is a blurred class, not an unnumbered one: a class of twenty tiles
    // with one ID stays labelled when most of the plan's tiles are in labelled classes.
    let inLabelled = found.filter { labelledIndices.contains($0.cls) }.count
    if inLabelled * 2 >= found.count {
        for k in legend.indices where !labelledIndices.contains(k) && isColoured(legend[k]) {
            let members = found.filter { $0.cls == k }
            if members.count >= 20, members.contains(where: { $0.item.id != nil }) { labelledIndices.insert(k) }
        }
    }
    let labelledNames = Set(labelledIndices.map { legend[$0].name })
    // Blur can leave a class with too few readable IDs to count as labelled, so a small tile also passes when it is as
    // wide as the plan's typical booth, which the thin fragments that the rule is there to drop are not.
    let readSides = found.filter { $0.item.id != nil }.map(\.item.shortSide).sorted()
    let boothSide = readSides.count >= 8 ? readSides[readSides.count / 2] : unit
    // White, black and grey classes are left out of that: their regions are the plan's own text and outlines.
    found = found.filter {
        !$0.small || labelledIndices.contains($0.cls) || (isColoured(legend[$0.cls]) && $0.item.shortSide >= 0.8 * boothSide)
    }
    var items: [Item] = []
    var colorReasons: [[String]] = []
    for var f in found {
        if !labelledIndices.contains(f.cls) {
            f.item.id = nil
            f.item.text = ""
        }
        items.append(f.item)
        colorReasons.append(f.colorReasons)
    }
    rebuildLabelledReasons(&items, labelledClasses: labelledNames, colorReasons: colorReasons)
    return LegendLayerOutput(items: items, labelledClasses: labelledNames, colorReasons: colorReasons, scale: scale)
}

/// Splits a region that is a whole number of small booths across and down (at least two booths) into equal cells
/// and reads each. The split stands when at least two cells and half of them read different valid IDs, so a real
/// double-width booth, which has one label, is left alone. The whole region can read as its first label, so this
/// runs for every region.
func mergedTiles(_ image: CGImage, _ rect: CGRect, unit: Double) async throws -> [(rect: CGRect, raw: String?, label: String?)]? {
    let (cols, rows) = (Int((rect.width / unit).rounded()), Int((rect.height / unit).rounded()))
    guard cols * rows >= 2, cols * rows <= 12, cols >= 1, rows >= 1,
          abs(rect.width / unit - Double(cols)) <= 0.35, abs(rect.height / unit - Double(rows)) <= 0.35 else { return nil }
    var slices: [(rect: CGRect, raw: String?, label: String?)] = []
    for row in 0..<rows {
        for col in 0..<cols {
            let part = CGRect(
                x: rect.minX + rect.width * Double(col) / Double(cols), y: rect.minY + rect.height * Double(row) / Double(rows),
                width: rect.width / Double(cols), height: rect.height / Double(rows))
            let raw = try await readLabel(image, in: part)
            slices.append((part, raw, raw.flatMap { cleanLabel($0) }))
        }
    }
    let labels = slices.compactMap(\.label)
    // Booths of one block are one series, so their labels share a prefix; a sponsor box whose name reads as scraps does not.
    let prefixes = Dictionary(grouping: labels) { $0.prefix { $0.isLetter } }
    let sameSeries = (prefixes.values.map(\.count).max() ?? 0) * 10 >= labels.count * 7
    let readsWell = labels.count >= 2 && labels.count * 2 >= slices.count && Set(labels).count == labels.count && sameSeries
    return readsWell ? slices : nil
}

func makeMaskedUpscaledCrop(_ image: CGImage, item: Item, scale: Int) -> CGImage? {
    let bx = item.box[0], by = item.box[1], bw = item.box[2], bh = item.box[3]
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let srcRect = CGRect(x: bx, y: by, width: bw, height: bh).intersection(bounds)
    guard srcRect.width >= 2, srcRect.height >= 2, let sub = image.cropping(to: srcRect) else { return nil }
    let pad = max(2, Int((0.2 * Double(min(bw, bh))).rounded()))
    let cw = (Int(srcRect.width) + 2 * pad) * scale
    let ch = (Int(srcRect.height) + 2 * pad) * scale
    guard let ctx = CGContext(
        data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
    ctx.saveGState()
    if let poly = item.polygon, poly.count >= 3 {
        let path = CGMutablePath()
        for (idx, pt) in poly.enumerated() {
            let px = CGFloat(Double(pt[0]) - Double(srcRect.minX) + Double(pad)) * CGFloat(scale)
            let py = CGFloat(Double(srcRect.height) - (Double(pt[1]) - Double(srcRect.minY)) + Double(pad)) * CGFloat(scale)
            if idx == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
    }
    ctx.interpolationQuality = .high
    ctx.draw(sub, in: CGRect(
        x: pad * scale, y: pad * scale,
        width: Int(srcRect.width) * scale, height: Int(srcRect.height) * scale
    ))
    ctx.restoreGState()
    return ctx.makeImage()
}

// Booths drawn as light boxes on a coloured zone have no legend colour of their own, so they are
// found as closed light regions of booth size and kept only when an ID reads inside.
func outlinedLayer(_ image: CGImage, _ px: Pixels, existing: [Item], scale: Double, lineScale: Int = 1) async -> [Item] {
    let (w, h) = (px.width, px.height)
    let outlines = morph(outlinePixels(px, lineScale: lineScale), w: w, h: h, rx: 1, ry: 1, erode: false)
    let minSide = Int(16 * scale), maxSide = Int(140 * Double(px.page) / 2000)
    var items: [Item] = []
    var misread: [(Item, String)] = []
    for face in components(outlines.map { !$0 }, w: w, h: h, eight: false) {
        guard min(face.width, face.height) >= minSide, max(face.width, face.height) <= maxSide,
              face.minX > 0, face.minY > 0, face.maxX < w - 1, face.maxY < h - 1,
              face.fill >= 0.6, face.fill < 0.98
        else { continue }
        let light = face.pixels.filter { i in
            let c = px.rgb(i % w, i / w)
            return min(c.0, min(c.1, c.2)) >= 235
        }.count
        guard Double(light) >= 0.7 * Double(face.area) else { continue }
        let rect = CGRect(x: face.minX, y: face.minY, width: face.width, height: face.height)
            .insetBy(dx: -2 * scale, dy: -2 * scale)
        guard !existing.contains(where: { boxIoU($0.box, box(rect)) >= 0.3 }) else { continue }
        var tile = outsideItem("Booth", rect, review: false, reason: nil)
        guard let crop = makeMaskedUpscaledCrop(image, item: tile, scale: 3),
              let found = try? await makeTextRequest().perform(on: crop) else { continue }
        let reads = found.sorted { $0.confidence > $1.confidence }.map(\.transcript)
        tile.fillRgb = [255, 255, 255]
        tile.legendRgb = [255, 255, 255]
        tile.source = "outlined"
        if let read = reads.compactMap({ text in cleanLabel(text).map { (text, $0) } }).first {
            tile.cls = "Booth " + String(read.1.prefix { $0.isLetter })
            tile.text = read.0
            tile.id = read.1
            items.append(tile)
        } else if let text = reads.first(where: { $0.contains { $0.isNumber } }) {
            misread.append((tile, text))
        }
    }
    // A booth whose prefix letter read as a digit takes the prefix of the nearest booth that read cleanly.
    for (var tile, text) in misread {
        guard let near = items.min(by: { distance($0, tile) < distance($1, tile) }),
              distance(near, tile) <= 3 * max(near.longSide, tile.longSide),
              let prefix = near.id?.first(where: { $0.isLetter }),
              let label = labelWithLeadingLookalike(text, prefix: prefix),
              !items.contains(where: { $0.id == label })
        else { continue }
        tile.cls = near.cls
        tile.text = text
        tile.id = label
        items.append(tile)
    }
    return items
}

private func distance(_ a: Item, _ b: Item) -> Double {
    hypot(a.centerX - b.centerX, a.centerY - b.centerY)
}

/// Tiles without an ID whose text is a number with a lookalike where the letter belongs ("521" for S21) take the
/// prefix of the nearest tile that read an ID, if that prefix's letter is a lookalike of the first character and the
/// result is not taken. Booths of one series sit together, so the nearest read tile is the best witness for the letter.
func restoreMisreadPrefixes(_ items: inout [Item], among indices: [Int]) {
    let read = items.indices.filter { items[$0].id != nil }
    var taken = Set(items.compactMap(\.id))
    for idx in indices where items[idx].id == nil {
        guard let near = read.min(by: { distance(items[$0], items[idx]) < distance(items[$1], items[idx]) }),
              distance(items[near], items[idx]) <= 3 * max(items[near].longSide, items[idx].longSide),
              let prefix = items[near].id?.first(where: { $0.isLetter }),
              let label = labelWithLeadingLookalike(items[idx].text, prefix: prefix),
              !taken.contains(label)
        else { continue }
        items[idx].id = label
        taken.insert(label)
    }
}

func rereadTiles(
    _ image: CGImage,
    content: CGRect,
    items: inout [Item],
    labelledClasses: Set<String>,
    colorReasons: [[String]],
    outDir: URL,
    apply: Bool,
    ruleCounts: inout [String: Int]
) async throws -> RereadStats {
    let idShorts = items.filter { $0.id != nil }.map(\.shortSide).sorted()
    let medianIdShort = idShorts.isEmpty ? 0 : idShorts[idShorts.count / 2]
    let blankIndices = items.indices.filter { i in
        guard items[i].id == nil else { return false }
        if labelledClasses.contains(items[i].cls) { return true }
        return medianIdShort > 0 && (0.5...2.5).contains(items[i].shortSide / medianIdShort)
    }
    let cropsDir = outDir.appendingPathComponent("crops")
    try FileManager.default.createDirectory(at: cropsDir, withIntermediateDirectories: true)
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var dumped = 0
    for idx in blankIndices {
        let b = items[idx].box
        if let rawCrop = image.cropping(to: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]).intersection(bounds)) {
            let safeCls = items[idx].cls.replacingOccurrences(of: " ", with: "_")
            let name = "tile_\(idx)_\(safeCls)_\(b[0])_\(b[1]).png"
            savePNG(rawCrop, to: cropsDir.appendingPathComponent(name))
            dumped += 1
        }
    }

    guard !blankIndices.isEmpty else {
        return RereadStats(
            blankTilesBefore: 0, cropsDumped: dumped, maskedCropRecovered: 0,
            pageTextRecovered: 0, pageTextAdditionalRecovered: 0, totalRecovered: 0, applied: apply
        )
    }

    var maskedHits: [Int: (raw: String, cleaned: String?)] = [:]
    for idx in blankIndices {
        var bestRaw: String?
        var bestClean: String?
        var bestScore = -1.0
        for scale in [2, 3] {
            guard let up = makeMaskedUpscaledCrop(image, item: items[idx], scale: scale) else { continue }
            let read = try await makeTextRequest().perform(on: up)
            let lines = read.map { ($0.transcript, Double($0.confidence)) } + [(stackedText(read), 0.5)]
            for (text, confidence) in lines {
                let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let cleaned = cleanLabel(raw)
                let score = (cleaned != nil ? 10.0 : 0.0) + confidence
                if score > bestScore {
                    bestScore = score
                    bestRaw = raw
                    bestClean = cleaned
                }
            }
        }
        if let raw = bestRaw {
            maskedHits[idx] = (raw, bestClean)
        }
    }

    let labelledShorts = items.filter { labelledClasses.contains($0.cls) }.map(\.shortSide).sorted()
    let medianShort = labelledShorts.isEmpty ? 40.0 : labelledShorts[labelledShorts.count / 2]
    var pageObs = try await recognizePageText(makeTextRequest(), in: image, content: content, minimumTextHeight: 0.15 * medianShort)
    // When a fifth of the tiles are still unread the plan is blurred or compressed, and the enlarged strips read more.
    let labelledCount = items.filter { labelledClasses.contains($0.cls) }.count
    if blankIndices.count * 5 > labelledCount {
        pageObs += try await recognizeSharpenedStrips(makeTextRequest(), in: image, content: content)
        pageObs += try await recognizeSharpenedStrips(makeTextRequest(), in: image, content: content, factor: 2, sharpen: false)
    }

    // Assign each page-level text box to the single labelled tile that owns its center pixel.
    var pageHits: [Int: (raw: String, cleaned: String?, score: Double)] = [:]
    let labelledItemIndices = items.indices.filter { labelledClasses.contains(items[$0].cls) }
    for obs in pageObs {
        let raw = obs.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { continue }
        let b = obs.box
        let center = CGPoint(x: b.midX, y: b.midY)
        var owner: Int?
        var ownerArea = Int.max
        for ti in labelledItemIndices where items[ti].rect.contains(center) {
            if let poly = items[ti].polygon, poly.count >= 3, !pointInPolygon(center, poly) {
                continue
            }
            if items[ti].area < ownerArea {
                ownerArea = items[ti].area
                owner = ti
            }
        }
        guard let ti = owner else { continue }
        let cleaned = cleanLabel(raw)
        let score = (cleaned != nil ? 10.0 : 0.0) + Double(obs.confidence)
        if score > (pageHits[ti]?.score ?? -1.0) {
            pageHits[ti] = (raw, cleaned, score)
        }
    }

    var maskedRecoveredCount = 0
    var pageRecoveredCount = 0
    var pageAdditionalCount = 0
    var totalRecoveredCount = 0

    for idx in blankIndices {
        let mHit = maskedHits[idx]
        let pHit = pageHits[idx]
        let mValid = mHit?.cleaned != nil
        let pValid = pHit?.cleaned != nil
        if mValid { maskedRecoveredCount += 1 }
        if pValid { pageRecoveredCount += 1 }
        if !mValid && pValid { pageAdditionalCount += 1 }

        let chosen: (raw: String, cleaned: String?)?
        if mValid {
            chosen = mHit
        } else if let p = pHit, pValid {
            chosen = (p.raw, p.cleaned)
        } else if let m = mHit {
            chosen = m
        } else if let p = pHit {
            chosen = (p.raw, p.cleaned)
        } else {
            chosen = nil
        }

        if let chosen, chosen.cleaned != nil {
            totalRecoveredCount += 1
        }
        if apply, let chosen {
            items[idx].text = chosen.raw
            items[idx].id = chosen.cleaned
            if chosen.cleaned != nil {
                ruleCounts["reread-tile", default: 0] += 1
            }
        }
    }

    if apply {
        restoreMisreadPrefixes(&items, among: blankIndices)
        rebuildLabelledReasons(&items, labelledClasses: labelledClasses, colorReasons: colorReasons)
    }

    return RereadStats(
        blankTilesBefore: blankIndices.count,
        cropsDumped: dumped,
        maskedCropRecovered: maskedRecoveredCount,
        pageTextRecovered: pageRecoveredCount,
        pageTextAdditionalRecovered: pageAdditionalCount,
        totalRecovered: totalRecoveredCount,
        applied: apply
    )
}
