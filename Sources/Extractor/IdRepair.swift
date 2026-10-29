import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

func expandOCRDigits(_ chars: [Character]) -> [String] {
    var acc = [""]
    for c in chars {
        let choices: [String]
        switch c {
        case "I", "L", "|", "E": choices = ["1"]
        case "O": choices = ["0"]
        case "Z": choices = ["7", "2"]
        default:
            guard c.isNumber else { return [] }
            choices = [String(c)]
        }
        var next: [String] = []
        for prefix in acc {
            for ch in choices { next.append(prefix + ch) }
        }
        acc = next
    }
    return acc
}

func prefixMatchesLeadingDigit(prefix: String, digit: Character) -> Bool {
    guard prefix.count == 1, let p = prefix.first else { return false }
    switch p {
    case "I", "L": return digit == "1"
    case "O": return digit == "0"
    case "Z": return digit == "7" || digit == "2"
    default: return false
    }
}

func checkMonotoneNumbers(_ values: [Int]) -> Int? {
    guard values.count >= 2 else { return nil }
    let inc = zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    if inc { return 1 }
    let dec = zip(values, values.dropFirst()).allSatisfy { $0 > $1 }
    if dec { return -1 }
    return nil
}

func assignMonotoneSequence(
    known: [(idx: Int, num: Int)],
    candidates: [Int],
    gaps: [Int],
    items: [Item]
) -> [(idx: Int, gap: Int, axisDesc: String)]? {
    guard known.count >= 2, candidates.count == gaps.count, !gaps.isEmpty else { return nil }
    let allKnownNums = Set(known.map(\.num))

    func trySubset(
        subsetKnown: [(idx: Int, num: Int)],
        horizontalAxis: Bool,
        scopeLabel: String,
        enforceContiguousRange: Bool
    ) -> [(idx: Int, gap: Int, axisDesc: String)]? {
        guard subsetKnown.count >= 2 else { return nil }
        func coord(_ idx: Int) -> Double { horizontalAxis ? items[idx].centerX : items[idx].centerY }
        let orderedKnown = subsetKnown.sorted { coord($0.idx) < coord($1.idx) }
        for k in 1..<orderedKnown.count where abs(coord(orderedKnown[k].idx) - coord(orderedKnown[k - 1].idx)) < 1e-6 {
            return nil
        }
        guard let dir = checkMonotoneNumbers(orderedKnown.map(\.num)) else { return nil }

        struct Entry { let idx: Int; let knownNum: Int? }
        var combined: [Entry] = orderedKnown.map { Entry(idx: $0.idx, knownNum: $0.num) }
            + candidates.map { Entry(idx: $0, knownNum: nil) }
        combined.sort { coord($0.idx) < coord($1.idx) }

        let orderedGaps = dir > 0 ? gaps.sorted() : gaps.sorted(by: >)
        var gapPos = 0
        var fullNumbers: [Int] = []
        var assignments: [(idx: Int, gap: Int, axisDesc: String)] = []
        let axisName = horizontalAxis ? "x" : "y"

        for entry in combined {
            if let n = entry.knownNum {
                fullNumbers.append(n)
            } else {
                let g = orderedGaps[gapPos]
                gapPos += 1
                fullNumbers.append(g)
                assignments.append((entry.idx, g, "\(scopeLabel) monotone \(axisName)-axis"))
            }
        }
        guard checkMonotoneNumbers(fullNumbers) == dir else { return nil }
        if enforceContiguousRange, let lo = fullNumbers.min(), let hi = fullNumbers.max() {
            let subsetSet = Set(fullNumbers)
            let outsideNums = allKnownNums.subtracting(subsetSet)
            if outsideNums.contains(where: { (lo...hi).contains($0) }) {
                return nil
            }
        }
        return assignments
    }

    let allIndices = known.map(\.idx) + candidates
    let xs = allIndices.map { items[$0].centerX }
    let ys = allIndices.map { items[$0].centerY }
    let spreadX = (xs.max() ?? 0) - (xs.min() ?? 0)
    let spreadY = (ys.max() ?? 0) - (ys.min() ?? 0)
    let primaryHorizontal = spreadX >= spreadY

    if let hit = trySubset(subsetKnown: known, horizontalAxis: primaryHorizontal, scopeLabel: "class", enforceContiguousRange: false) {
        return hit
    }
    if let hit = trySubset(subsetKnown: known, horizontalAxis: !primaryHorizontal, scopeLabel: "class", enforceContiguousRange: false) {
        return hit
    }

    // Wrapped perimeter classes remain monotone along individual collinear rows or columns.
    let longs = allIndices.map { items[$0].longSide }.sorted()
    let bandTol = longs[longs.count / 2]
    let candXs = candidates.map { items[$0].centerX }
    let candYs = candidates.map { items[$0].centerY }
    let candSpreadX = (candXs.max() ?? 0) - (candXs.min() ?? 0)
    let candSpreadY = (candYs.max() ?? 0) - (candYs.min() ?? 0)

    if candSpreadX <= bandTol {
        let meanX = candXs.reduce(0, +) / Double(candXs.count)
        let bandKnown = known.filter { abs(items[$0.idx].centerX - meanX) <= bandTol }
        if let hit = trySubset(subsetKnown: bandKnown, horizontalAxis: false, scopeLabel: "column", enforceContiguousRange: true) {
            return hit
        }
    }
    if candSpreadY <= bandTol {
        let meanY = candYs.reduce(0, +) / Double(candYs.count)
        let bandKnown = known.filter { abs(items[$0.idx].centerY - meanY) <= bandTol }
        if let hit = trySubset(subsetKnown: bandKnown, horizontalAxis: true, scopeLabel: "row", enforceContiguousRange: true) {
            return hit
        }
    }
    return nil
}

func computeClassPrefixes(_ items: [Item]) -> [String: String] {
    let byClass = Dictionary(grouping: items.indices, by: { items[$0].cls })
    var out: [String: String] = [:]
    for (cls, indices) in byClass {
        var prefixCounts: [String: Int] = [:]
        var totalParsed = 0
        for idx in indices {
            if let parsed = parseStrictId(items[idx].id) {
                prefixCounts[parsed.prefix, default: 0] += 1
                totalParsed += 1
            }
        }
        guard totalParsed > 0, totalParsed * 2 >= indices.count,
              let top = prefixCounts.max(by: { $0.value < $1.value }),
              top.value * 10 >= totalParsed * 7
        else { continue }
        out[cls] = top.key
    }
    return out
}

func computeUnresolvedGapIds(items: [Item], classPrefixes: [String: String]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    let byClass = Dictionary(grouping: items.indices, by: { items[$0].cls })
    for (cls, prefix) in classPrefixes {
        guard let indices = byClass[cls] else { continue }
        var present = Set<Int>()
        var extraCount = 0
        for idx in indices {
            if let parsed = parseStrictId(items[idx].id), parsed.prefix == prefix {
                present.insert(parsed.number)
            } else {
                let raw = foldLookalikes((items[idx].id ?? items[idx].text).uppercased()).filter { !$0.isWhitespace }
                if let first = raw.first, prefixMatchesLeadingDigit(prefix: prefix, digit: first),
                   let n = Int(raw.dropFirst()), n >= 1, !present.contains(n)
                {
                    extraCount = max(extraCount, n)
                }
            }
        }
        let maxNum = max(present.max() ?? 0, extraCount)
        guard maxNum >= 1 else { continue }
        let missing = Set(1...maxNum).subtracting(present).sorted()
        if !missing.isEmpty {
            result[cls] = missing.map { "\(prefix)\($0)" }
        }
    }
    return result
}

func repairIds(_ items: inout [Item], classPrefixes: [String: String], ruleCounts: inout [String: Int]) {
    var classesByExactId: [String: Set<String>] = [:]
    for item in items {
        if let id = item.id {
            classesByExactId[id, default: []].insert(item.cls)
        }
    }

    let byClass = Dictionary(grouping: items.indices, by: { items[$0].cls })
    for cls in classPrefixes.keys.sorted() {
        guard let prefix = classPrefixes[cls], let indices = byClass[cls] else { continue }

        for idx in indices where !items[idx].needsReview {
            if let parsed = parseStrictId(items[idx].id), parsed.prefix == prefix {
                continue
            }
            items[idx].needsReview = true
            let shown = items[idx].id ?? items[idx].text
            let msg = "id \"\(shown)\" does not match class pattern \"\(prefix)<n>\""
            items[idx].reason = items[idx].reason.map { "\($0); \(msg)" } ?? msg
            if items[idx].fixRule == nil {
                items[idx].fixRule = "id-pattern"
                items[idx].fixReason = msg
            }
            ruleCounts["id-pattern", default: 0] += 1
        }

        var known: [(idx: Int, num: Int)] = []
        var effectivePresent = Set<Int>()
        var unresolved: [Int] = []

        for idx in indices {
            if let parsed = parseStrictId(items[idx].id), parsed.prefix == prefix {
                known.append((idx, parsed.number))
                effectivePresent.insert(parsed.number)
            } else {
                unresolved.append(idx)
            }
        }
        guard !effectivePresent.isEmpty else { continue }

        // Resolve prefix-digit OCR confusions such as "19" -> I9 before counting remaining gaps.
        var stillUnresolved: [Int] = []
        for idx in unresolved {
            let raw = Array(foldLookalikes((items[idx].id ?? items[idx].text).uppercased()).filter { !$0.isWhitespace })
            let curMax = effectivePresent.max() ?? 0
            if raw.count >= 2, prefixMatchesLeadingDigit(prefix: prefix, digit: raw[0]),
               raw.dropFirst().allSatisfy(\.isNumber),
               let n = Int(String(raw.dropFirst())),
               (1...(curMax + 1)).contains(n), !effectivePresent.contains(n)
            {
                items[idx].suggestedId = "\(prefix)\(n)"
                items[idx].fixRule = "ocr-confusion"
                items[idx].fixReason = "\"\(String(raw))\" has leading digit \"\(raw[0])\" confused with prefix \"\(prefix)\""
                effectivePresent.insert(n)
                ruleCounts["ocr-confusion", default: 0] += 1
            } else {
                stillUnresolved.append(idx)
            }
        }
        unresolved = stillUnresolved

        guard let maxNum = effectivePresent.max(), maxNum >= 1 else { continue }
        var remainingGaps = Set(1...maxNum).subtracting(effectivePresent).sorted()

        stillUnresolved = []
        for idx in unresolved {
            if let id = items[idx].id, let parsed = parseStrictId(id), parsed.prefix != prefix,
               remainingGaps.contains(parsed.number),
               let holders = classesByExactId[id], holders.contains(where: { $0 != cls })
            {
                items[idx].suggestedId = "\(prefix)\(parsed.number)"
                items[idx].fixRule = "prefix-conflict"
                items[idx].fixReason = "\"\(id)\" already exists in another class and \(prefix)\(parsed.number) is a gap here"
                remainingGaps.removeAll { $0 == parsed.number }
                effectivePresent.insert(parsed.number)
                ruleCounts["prefix-conflict", default: 0] += 1
            } else {
                stillUnresolved.append(idx)
            }
        }
        unresolved = stillUnresolved

        guard !remainingGaps.isEmpty, unresolved.count == remainingGaps.count else { continue }

        var gapSet = Set(remainingGaps)
        var ocrMatched: [(idx: Int, gap: Int, raw: String)] = []
        for idx in unresolved {
            let token = Array(foldLookalikes((items[idx].id ?? items[idx].text).uppercased()).filter { !$0.isWhitespace })
            guard token.count > prefix.count, String(token.prefix(prefix.count)) == prefix else { continue }
            let tail = Array(token.dropFirst(prefix.count))
            let landings = Set(expandOCRDigits(tail).compactMap { Int($0) }).intersection(gapSet)
            if landings.count == 1, let g = landings.first {
                ocrMatched.append((idx, g, String(token)))
            }
        }

        let usedGapsCounts = Dictionary(ocrMatched.map { ($0.gap, 1) }, uniquingKeysWith: +)
        var resolvedByOCR = Set<Int>()
        for m in ocrMatched where usedGapsCounts[m.gap] == 1 {
            items[m.idx].suggestedId = "\(prefix)\(m.gap)"
            items[m.idx].fixRule = "ocr-confusion"
            items[m.idx].fixReason = "OCR substitution on \"\(m.raw)\" lands uniquely on gap \(prefix)\(m.gap)"
            gapSet.remove(m.gap)
            resolvedByOCR.insert(m.idx)
            known.append((m.idx, m.gap))
            ruleCounts["ocr-confusion", default: 0] += 1
        }

        let leftCandidates = unresolved.filter { !resolvedByOCR.contains($0) }
        let leftGaps = gapSet.sorted()
        guard !leftGaps.isEmpty, leftCandidates.count == leftGaps.count else { continue }

        if leftCandidates.count == 1 {
            let idx = leftCandidates[0], g = leftGaps[0]
            items[idx].suggestedId = "\(prefix)\(g)"
            items[idx].fixRule = "id-sequence"
            items[idx].fixReason = "sole candidate in class assigned sole missing number \(prefix)\(g)"
            ruleCounts["id-sequence", default: 0] += 1
        } else if let assigned = assignMonotoneSequence(
            known: known, candidates: leftCandidates, gaps: leftGaps, items: items
        ) {
            for a in assigned {
                items[a.idx].suggestedId = "\(prefix)\(a.gap)"
                items[a.idx].fixRule = "id-sequence"
                items[a.idx].fixReason = "assigned \(prefix)\(a.gap) by \(a.axisDesc) position"
                ruleCounts["id-sequence", default: 0] += 1
            }
        }
    }
}

// The per-class repair assumes one prefix per class. Plans that group booths by country or zone mix
// prefixes, so OCR slips are found against the plan's own prefix counts and number series instead.
// Results are suggestions only, like the per-class rules.
func repairIdsByPrefix(_ items: inout [Item], ruleCounts: inout [String: Int]) {
    let digitFor: [Character: Character] = ["O": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8", "G": "6"]
    let letterPairs: [(Character, Character)] = [("C", "G"), ("B", "E")]
    let digitPairs: [Character: [Character]] = ["1": ["7"], "7": ["1"], "3": ["8"], "8": ["3", "0", "6"], "0": ["8"], "5": ["6"], "6": ["5", "8"], "4": ["9"], "9": ["4"]]
    func split(_ id: String) -> (prefix: String, tail: String)? {
        guard let parsed = parseStrictId(id) else { return nil }
        return (parsed.prefix, String(id.dropFirst(parsed.prefix.count)))
    }

    var prefixCounts: [String: Int] = [:]
    var held = Set<String>()
    var numbers: [String: Set<Int>] = [:]
    var idCounts: [String: Int] = [:]
    var widths: [String: Int] = [:]
    for item in items {
        guard let id = item.id else { continue }
        idCounts[id, default: 0] += 1
        guard let parts = split(id) else { continue }
        prefixCounts[parts.prefix, default: 0] += 1
        held.insert(id)
        numbers[parts.prefix, default: []].insert(Int(parts.tail) ?? 0)
        widths[parts.prefix] = max(widths[parts.prefix] ?? 0, parts.tail.count)
    }
    func common(_ prefix: String) -> Bool { prefixCounts[prefix, default: 0] >= 5 }
    func lessCommon(_ prefix: String, than other: String) -> Bool { prefixCounts[prefix, default: 0] < prefixCounts[other, default: 0] }

    for i in items.indices where items[i].suggestedId == nil {
        guard let id = items[i].id, let parts = split(id) else { continue }
        var suggestion: (id: String, rule: String, reason: String)?

        if parts.prefix.count >= 2, let last = parts.prefix.last, let digit = digitFor[last] {
            let short = String(parts.prefix.dropLast())
            let candidate = short + String(digit) + parts.tail
            if common(short), lessCommon(parts.prefix, than: short), !held.contains(candidate) {
                suggestion = (candidate, "ocr-prefix-digit", "\"\(id)\" reads \"\(last)\" for a leading zero after the common prefix \"\(short)\"")
            }
        }
        if suggestion == nil {
            for (a, b) in letterPairs {
                for (from, to) in [(a, b), (b, a)] {
                    for (offset, ch) in parts.prefix.enumerated() where ch == from {
                        var chars = Array(parts.prefix)
                        chars[offset] = to
                        let prefix = String(chars)
                        if suggestion == nil, common(prefix), prefixCounts[parts.prefix, default: 0] * 3 < prefixCounts[prefix, default: 0], !held.contains(prefix + parts.tail) {
                            suggestion = (prefix + parts.tail, "ocr-prefix-letter", "prefix \"\(parts.prefix)\" is less common than \"\(prefix)\", which differs by \(from) and \(to)")
                        }
                    }
                }
            }
        }
        if suggestion == nil, idCounts[id, default: 0] > 1, let top = numbers[parts.prefix]?.max(),
           parts.tail.count == String(top).count || parts.tail.count == widths[parts.prefix] {
            var landings: [String] = []
            for (offset, ch) in parts.tail.enumerated() {
                for swap in digitPairs[ch] ?? [] {
                    var chars = Array(parts.tail)
                    chars[offset] = swap
                    let tail = String(chars)
                    if let n = Int(tail), n >= 1, n <= top, !(numbers[parts.prefix]?.contains(n) ?? false) {
                        landings.append(parts.prefix + tail)
                    }
                }
            }
            if Set(landings).count == 1, let only = landings.first {
                suggestion = (only, "ocr-duplicate", "\"\(id)\" is read twice and one digit swap lands on the missing \(only)")
            }
        }

        if let found = suggestion {
            items[i].suggestedId = found.id
            items[i].fixRule = found.rule
            items[i].fixReason = found.reason
            held.insert(found.id)
            if let parts = split(found.id) { numbers[parts.prefix, default: []].insert(Int(parts.tail) ?? 0) }
            ruleCounts[found.rule, default: 0] += 1
        }
    }
}
