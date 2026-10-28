import Foundation

public enum RepairRule: String, CaseIterable {
    case ocrConfusion = "ocr-confusion"
    case prefixConflict = "prefix-conflict"
    case idSequence = "id-sequence"
    case moduleMerge = "module-merge"
    case opening = "thickness-transition"
    case sizeOutlier = "size-outlier"
}

public struct Change: Equatable {
    public var rule: String
    public var index: Int?
    public var message: String
}

public struct RepairResult {
    public var items: [LayoutItem]
    public var changes: [Change]
}

// The outside layer's own vocabulary. These are not venue legend classes.
enum Kind {
    static let wall = "wall"
    static let door = "door"
    static let object = "object"
}

let ocrSubstitutions: [Character: [Character]] = [
    "I": ["1"], "L": ["1"], "|": ["1"], "O": ["0"], "Z": ["7", "2"], "E": ["1"],
]

struct ParsedID {
    let prefix: String
    let number: Int
}

func parseID(_ id: String) -> ParsedID? {
    let letters = id.prefix { !$0.isNumber }
    let digits = id.dropFirst(letters.count)
    guard !letters.isEmpty, letters.allSatisfy(\.isLetter), !digits.isEmpty,
          digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 1
    else { return nil }
    return ParsedID(prefix: String(letters), number: n)
}

struct ClassInfo {
    let name: String
    let prefix: String
    let indices: [Int]
}

// A class is numbered when most of its parseable ids share one prefix. Nothing here knows a class name.
func numberedClasses(_ items: [LayoutItem]) -> [ClassInfo] {
    var byClass: [String: [Int]] = [:]
    for (i, item) in items.enumerated() { byClass[item.cls, default: []].append(i) }
    return byClass.keys.sorted().compactMap { name in
        let indices = byClass[name]!
        var tally: [String: Int] = [:]
        for i in indices { if let id = items[i].id, let p = parseID(id) { tally[p.prefix, default: 0] += 1 } }
        let top = tally.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
        guard let top, top.value >= 2, top.value * 2 >= tally.values.reduce(0, +) else { return nil }
        return ClassInfo(name: name, prefix: top.key, indices: indices)
    }
}

func number(of item: LayoutItem, prefix: String) -> Int? {
    guard let id = item.suggestedId ?? item.id, let p = parseID(id), p.prefix == prefix else { return nil }
    return p.number
}

func digitReadings(_ text: String) -> [String] {
    guard !text.isEmpty, text.count <= 4 else { return [] }
    var out = [""]
    for ch in text.uppercased() {
        let options: [Character] = ch.isNumber ? [ch] : (ocrSubstitutions[ch] ?? [])
        if options.isEmpty { return [] }
        out = out.flatMap { head in options.map { head + String($0) } }
    }
    return out
}

func suggest(_ items: inout [LayoutItem], _ i: Int, _ id: String, rule: String, reason: String) -> Change {
    items[i].suggestedId = id
    items[i].fixRule = rule
    items[i].fixReason = reason
    items[i].needsReview = true
    let seen = items[i].id ?? (items[i].text.isEmpty ? "unlabeled" : items[i].text)
    return Change(rule: rule, index: i, message: "\(items[i].cls): \"\(seen)\" -> \(id), \(reason)")
}

// An id such as "19" is the class prefix "I" read as the digit 1 followed by 9. This runs before the
// gap rule because I9 can sit one past the highest known number, which is not a gap.
func completeConfusedPrefix(_ items: inout [LayoutItem]) -> [Change] {
    var changes: [Change] = []
    for cls in numberedClasses(items) {
        let readings = digitReadings(cls.prefix)
        var used = Set(cls.indices.compactMap { i in (items[i].suggestedId ?? items[i].id).flatMap { parseID($0) != nil ? $0 : nil } })
        var top = cls.indices.compactMap { number(of: items[$0], prefix: cls.prefix) }.max() ?? 0
        for i in cls.indices {
            guard items[i].suggestedId == nil, case let id = items[i].id ?? items[i].text, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            for reading in readings where id.hasPrefix(reading) && id.count > reading.count {
                guard let n = Int(id.dropFirst(reading.count)), n >= 1, n <= top + 1, !used.contains(cls.prefix + String(n)) else { continue }
                changes.append(suggest(&items, i, cls.prefix + String(n), rule: RepairRule.ocrConfusion.rawValue,
                                       reason: "id has no prefix letters and \"\(cls.prefix)\" reads as \"\(reading)\""))
                used.insert(cls.prefix + String(n))
                top = max(top, n)
                break
            }
        }
    }
    return changes
}

func resolvePrefixConflicts(_ items: inout [LayoutItem]) -> [Change] {
    var changes: [Change] = []
    for cls in numberedClasses(items) {
        let numbers = Set(cls.indices.compactMap { number(of: items[$0], prefix: cls.prefix) })
        guard let top = numbers.max() else { continue }
        var gaps = Set((1...top).filter { !numbers.contains($0) })
        let inClass = Set(cls.indices)
        let ownedElsewhere = Set(items.indices.filter { !inClass.contains($0) }.compactMap { items[$0].id })
        for i in cls.indices {
            guard items[i].suggestedId == nil, let id = items[i].id, let p = parseID(id), p.prefix != cls.prefix,
                  gaps.contains(p.number), ownedElsewhere.contains(id)
            else { continue }
            changes.append(suggest(&items, i, cls.prefix + String(p.number), rule: RepairRule.prefixConflict.rawValue,
                                   reason: "\(id) belongs to another class and \(p.number) is a gap in \(cls.name)"))
            gaps.remove(p.number)
        }
    }
    return changes
}

func bestAssignment(_ candidates: [Int], _ gaps: [Int], cost: (Int, Int) -> Double?) -> [Int: Int]? {
    guard candidates.count <= 7 else { return nil }
    var best: (total: Double, pairs: [Int: Int])?
    var tie = false
    func walk(_ k: Int, _ free: [Int], _ total: Double, _ pairs: [Int: Int]) {
        if k == candidates.count {
            if let b = best, abs(b.total - total) < 1e-6 { tie = true }
            if best == nil || total < best!.total { best = (total, pairs); tie = false }
            return
        }
        for (j, g) in free.enumerated() {
            guard let c = cost(candidates[k], g) else { continue }
            var rest = free; rest.remove(at: j)
            var next = pairs; next[candidates[k]] = g
            walk(k + 1, rest, total + c, next)
        }
    }
    walk(0, gaps, 0, [:])
    return tie ? nil : best?.pairs
}

func fillSequenceGaps(_ items: inout [LayoutItem], image: (w: Int, h: Int), useOCR: Bool) -> [Change] {
    var changes: [Change] = []
    let reach = 0.12 * Double(max(image.w, image.h))
    for cls in numberedClasses(items) {
        var holder: [Int: Int] = [:]
        var repeated = Set<Int>()
        for i in cls.indices {
            guard let n = number(of: items[i], prefix: cls.prefix) else { continue }
            if holder[n] != nil { repeated.insert(n) }
            holder[n] = i
        }
        guard let top = holder.keys.max() else { continue }
        var gaps = (1...top).filter { holder[$0] == nil }
        var candidates = cls.indices.filter { number(of: items[$0], prefix: cls.prefix) == nil }
        guard candidates.count == gaps.count else {
            if !candidates.isEmpty {
                changes.append(Change(rule: RepairRule.idSequence.rawValue, index: nil,
                                      message: "\(cls.name): \(candidates.count) unresolved, \(gaps.count) gaps, no suggestion"))
            }
            continue
        }
        if useOCR {
            for c in candidates {
                let text = items[c].text.uppercased().filter { !$0.isWhitespace }
                guard text.hasPrefix(cls.prefix.uppercased()) else { continue }
                let hits = Set(digitReadings(String(text.dropFirst(cls.prefix.count))).compactMap(Int.init).filter { gaps.contains($0) })
                guard hits.count == 1, let n = hits.first else { continue }
                changes.append(suggest(&items, c, cls.prefix + String(n), rule: RepairRule.ocrConfusion.rawValue,
                                       reason: "text \"\(items[c].text)\" reads as \(cls.prefix)\(n), which is a gap"))
                gaps.removeAll { $0 == n }
                candidates.removeAll { $0 == c }
                holder[n] = c
            }
        }
        if candidates.count == 1, let g = gaps.first {
            changes.append(suggest(&items, candidates[0], cls.prefix + String(g), rule: RepairRule.idSequence.rawValue,
                                   reason: "only unresolved tile and only missing number in \(cls.name)"))
        } else if candidates.count > 1 {
            func distance(_ c: Int, _ g: Int) -> Double? {
                let near = [g - 1, g + 1].compactMap { n -> Double? in
                    guard let h = holder[n], !repeated.contains(n) else { return nil }
                    return hypot(items[c].centerX - items[h].centerX, items[c].centerY - items[h].centerY)
                }
                guard let d = near.min(), d <= reach else { return nil }
                return d
            }
            guard let pairs = bestAssignment(candidates, gaps, cost: distance) else { continue }
            for c in candidates.sorted() {
                let g = pairs[c]!
                changes.append(suggest(&items, c, cls.prefix + String(g), rule: RepairRule.idSequence.rawValue,
                                       reason: "closest to \(cls.prefix)\(g - 1) and \(cls.prefix)\(g + 1)"))
            }
        }
    }
    return changes
}

// Shapes share a module when their short sides match and each long side is a whole multiple of its short side.
public func sameLook(_ a: LayoutItem, _ b: LayoutItem, tolerance: Double = 0.1) -> Bool {
    func isModular(_ s: LayoutItem) -> Bool {
        let k = max(1, (s.longSide / s.shortSide).rounded())
        return k <= 3 && abs(s.longSide - k * s.shortSide) <= tolerance * k * s.shortSide
    }
    return isModular(a) && isModular(b) && abs(a.shortSide - b.shortSide) <= tolerance * max(a.shortSide, b.shortSide)
}

public func moduleGroups(_ items: [LayoutItem]) -> [[Int]] {
    let eligible = items.indices.filter { items[$0].cls == Kind.object && items[$0].id == nil && items[$0].suggestedId == nil }
    var root = Dictionary(uniqueKeysWithValues: eligible.map { ($0, $0) })
    func find(_ i: Int) -> Int {
        var r = i
        while root[r]! != r { r = root[r]! }
        return r
    }
    for (n, i) in eligible.enumerated() {
        for j in eligible[(n + 1)...] where sameLook(items[i], items[j]) { root[find(j)] = find(i) }
    }
    var groups: [Int: [Int]] = [:]
    for i in eligible { groups[find(i), default: []].append(i) }
    return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
}

func mergeModules(_ items: inout [LayoutItem]) -> [Change] {
    var changes: [Change] = []
    for (g, members) in moduleGroups(items).enumerated() where members.count > 1 {
        for i in members {
            items[i].fixRule = RepairRule.moduleMerge.rawValue
            items[i].fixReason = "module group \(g + 1) of \(members.count) shapes with the same short side"
        }
        changes.append(Change(rule: RepairRule.moduleMerge.rawValue, index: members[0],
                              message: "module group \(g + 1): \(members.count) shapes merged"))
    }
    return changes
}

func iou(_ a: [Int], _ b: [Int]) -> Double {
    let w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    let h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    guard w > 0, h > 0 else { return 0 }
    let inter = Double(w * h)
    return inter / (Double(a[2] * a[3] + b[2] * b[3]) - inter)
}

func openingsFromThickness(_ items: [LayoutItem], image: (w: Int, h: Int)) -> [LayoutItem] {
    let mx = Double(max(image.w, image.h))
    let lineTolerance = 0.004 * mx, gapTolerance = 0.03 * mx, touch = 0.006 * mx
    var doors: [LayoutItem] = []
    for horizontal in [true, false] {
        let pieces = items.indices.filter { items[$0].cls == Kind.wall && (items[$0].box[2] >= items[$0].box[3]) == horizontal }
        func line(_ i: Int) -> Double { horizontal ? items[i].centerY : items[i].centerX }
        func start(_ i: Int) -> Double { Double(items[i].box[horizontal ? 0 : 1]) }
        func end(_ i: Int) -> Double { start(i) + Double(items[i].box[horizontal ? 2 : 3]) }
        func thickness(_ i: Int) -> Double { Double(items[i].box[horizontal ? 3 : 2]) }
        var lines: [[Int]] = []
        for i in pieces.sorted(by: { line($0) < line($1) }) {
            if let last = lines.last, abs(line(i) - last.map(line).reduce(0, +) / Double(last.count)) <= lineTolerance {
                lines[lines.count - 1].append(i)
            } else {
                lines.append([i])
            }
        }
        for cluster in lines where cluster.count >= 3 {
            let ordered = cluster.sorted { start($0) < start($1) }
            for j in 1..<(ordered.count - 1) {
                let (prev, cur, next) = (ordered[j - 1], ordered[j], ordered[j + 1])
                guard thickness(cur) < 0.5 * min(thickness(prev), thickness(next)),
                      start(cur) - end(prev) <= gapTolerance, start(next) - end(cur) <= gapTolerance
                else { continue }
                let run = items[cur].box
                if items.contains(where: { $0.cls == Kind.door && iou($0.box, run) > 0.3 }) { continue }
                let runX = Double(run[0]), runY = Double(run[1]), runW = Double(run[2]), runH = Double(run[3])
                let zoneX0 = runX - touch, zoneY0 = runY - touch
                let zoneX1 = runX + runW + touch, zoneY1 = runY + runH + touch
                let runCenterX = runX + runW / 2
                let runCenterY = runY + runH / 2
                var fill: Int?
                var fillRank = Double.infinity
                for i in items.indices where items[i].id == nil && items[i].cls != Kind.wall && items[i].cls != Kind.door {
                    let bx0 = Double(items[i].box[0]), by0 = Double(items[i].box[1])
                    let bx1 = bx0 + Double(items[i].box[2]), by1 = by0 + Double(items[i].box[3])
                    guard bx0 < zoneX1, bx1 > zoneX0, by0 < zoneY1, by1 > zoneY0 else { continue }
                    let white = (items[i].fillRgb.min() ?? 0) > 235
                    let dx = items[i].centerX - runCenterX, dy = items[i].centerY - runCenterY
                    let rank = (white ? 0.0 : 1e9) + (dx * dx + dy * dy).squareRoot()
                    if rank < fillRank { fill = i; fillRank = rank }
                }
                var door = LayoutItem(cls: Kind.door, box: run, reason: "thin run between thicker wall pieces")
                door.source = "thickness-transition"
                door.fillBox = fill.map { items[$0].box }
                door.fixRule = RepairRule.opening.rawValue
                door.fixReason = "thickness \(Int(thickness(cur))) is under half of \(Int(thickness(prev))) and \(Int(thickness(next)))"
                doors.append(door)
            }
        }
    }
    return doors
}

func flagSizeOutliers(_ items: inout [LayoutItem]) -> [Change] {
    let unresolved = items.indices.filter {
        items[$0].id == nil && items[$0].suggestedId == nil && items[$0].cls != Kind.wall && items[$0].cls != Kind.door
    }
    var groups: [[Int]] = []
    for i in unresolved {
        if let g = groups.firstIndex(where: {
            let ref = items[$0[0]]
            return ref.cls == items[i].cls && ref.fillRgb == items[i].fillRgb
                && abs(ref.shortSide - items[i].shortSide) <= 0.1 * max(ref.shortSide, items[i].shortSide)
        }) { groups[g].append(i) } else { groups.append([i]) }
    }
    var changes: [Change] = []
    for members in groups where members.count >= 3 {
        let areas = members.map { items[$0].area }.sorted()
        let median = areas.count % 2 == 1 ? Double(areas[areas.count / 2]) : Double(areas[areas.count / 2 - 1] + areas[areas.count / 2]) / 2
        for i in members where Double(items[i].area) > 2.5 * median {
            items[i].needsReview = true
            items[i].fixRule = RepairRule.sizeOutlier.rawValue
            items[i].fixReason = "area \(items[i].area) is \(String(format: "%.1f", Double(items[i].area) / median)) times the median of \(members.count) look-alike shapes"
            changes.append(Change(rule: RepairRule.sizeOutlier.rawValue, index: i, message: "\(items[i].cls): \(items[i].fixReason!)"))
        }
    }
    return changes
}

public func repair(_ items: [LayoutItem], image: (w: Int, h: Int), rules: Set<RepairRule> = Set(RepairRule.allCases)) -> RepairResult {
    var out = items
    var changes: [Change] = []
    if rules.contains(.ocrConfusion) { changes += completeConfusedPrefix(&out) }
    if rules.contains(.prefixConflict) { changes += resolvePrefixConflicts(&out) }
    if rules.contains(.idSequence) { changes += fillSequenceGaps(&out, image: image, useOCR: rules.contains(.ocrConfusion)) }
    if rules.contains(.moduleMerge) { changes += mergeModules(&out) }
    if rules.contains(.opening) {
        for door in openingsFromThickness(out, image: image) {
            out.append(door)
            changes.append(Change(rule: RepairRule.opening.rawValue, index: out.count - 1,
                                  message: "door at \(door.box) \(door.fixReason ?? "")"))
        }
    }
    if rules.contains(.sizeOutlier) { changes += flagSizeOutliers(&out) }
    return RepairResult(items: out, changes: changes)
}
