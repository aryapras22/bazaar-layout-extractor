import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

func makeOrientedObjectCrop(_ image: CGImage, box: [Int]) -> CGImage? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3]).intersection(bounds).integral
    guard rect.width >= 2, rect.height >= 2, let sub = image.cropping(to: rect) else { return nil }
    let w = sub.width, h = sub.height
    let outW = max(w, h), outH = min(w, h)
    let scale = max(1, Int((64.0 / Double(max(1, outH))).rounded(.up)))
    let cw = outW * scale, ch = outH * scale
    guard let ctx = CGContext(
        data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
    ctx.interpolationQuality = .high
    if h > w {
        ctx.translateBy(x: CGFloat(cw), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: ch, height: cw))
    } else {
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: cw, height: ch))
    }
    return ctx.makeImage()
}

func regroupObjects(
    _ image: CGImage,
    items: inout [Item],
    enableModule: Bool,
    enableFeaturePrint: Bool,
    ruleCounts: inout [String: Int]
) async -> FeaturePrintStats {
    let objIndices = items.indices.filter { items[$0].cls == "object" && items[$0].id == nil }
    guard !objIndices.isEmpty else {
        return FeaturePrintStats(
            enabled: enableFeaturePrint, intraGroupDistanceMedian: nil,
            groupsBefore: 0, groupsAfter: 0, extraMerges: 0, mergedMoreThanModule: false
        )
    }

    var keyedGroups: [String: [Int]] = [:]
    var orderedKeys: [String] = []
    for idx in objIndices {
        let reason = items[idx].reason ?? ""
        let key: String
        if reason.hasPrefix("label this group once (") {
            key = reason
        } else {
            key = "singleton-\(idx)"
        }
        if keyedGroups[key] == nil { orderedKeys.append(key) }
        keyedGroups[key, default: []].append(idx)
    }
    var groups: [[Int]] = orderedKeys.compactMap { keyedGroups[$0] }

    func groupShort(_ members: [Int]) -> Double {
        let s = members.map { items[$0].shortSide }.sorted()
        return s[s.count / 2]
    }
    func groupLong(_ members: [Int]) -> Double {
        let l = members.map { items[$0].longSide }.sorted()
        return l[l.count / 2]
    }
    func moduleFactor(_ members: [Int]) -> Int? {
        let s = groupShort(members), l = groupLong(members)
        guard s > 0 else { return nil }
        let k = Int((l / s).rounded())
        guard (1...3).contains(k), abs(l - Double(k) * s) <= 0.1 * Double(k) * s else { return nil }
        return k
    }

    var mergedByModuleIndices = Set<Int>()
    if enableModule {
        var parent = Array(groups.indices)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            return r
        }
        for a in groups.indices {
            guard moduleFactor(groups[a]) != nil else { continue }
            let sA = groupShort(groups[a])
            for b in (a + 1)..<groups.count {
                guard moduleFactor(groups[b]) != nil else { continue }
                let sB = groupShort(groups[b])
                if abs(sA - sB) <= 0.1 * max(sA, sB) {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[rb] = ra }
                }
            }
        }
        var bucketed: [Int: [[Int]]] = [:]
        var bucketOrder: [Int] = []
        for g in groups.indices {
            let r = find(g)
            if bucketed[r] == nil { bucketOrder.append(r) }
            bucketed[r, default: []].append(groups[g])
        }
        var nextGroups: [[Int]] = []
        for r in bucketOrder {
            let parts = bucketed[r]!
            let combined = parts.flatMap { $0 }
            nextGroups.append(combined)
            if parts.count > 1 {
                ruleCounts["module-merge", default: 0] += 1
                let s = Int(groupShort(combined).rounded())
                for idx in combined {
                    mergedByModuleIndices.insert(idx)
                    items[idx].fixRule = "module-merge"
                    items[idx].fixReason = "merged \(parts.count) modular object groups (1x..3x of short side \(s))"
                }
            }
        }
        groups = nextGroups
    }

    let groupsBeforeFP = groups.count
    var fpStats = FeaturePrintStats(
        enabled: enableFeaturePrint, intraGroupDistanceMedian: nil,
        groupsBefore: groupsBeforeFP, groupsAfter: groupsBeforeFP,
        extraMerges: 0, mergedMoreThanModule: false
    )

    if enableFeaturePrint, groups.count >= 2 {
        var intraDistances: [Double] = []
        var repPrints: [Int: FeaturePrintObservation] = [:]

        for g in groups.indices {
            let sampleMembers = Array(groups[g].prefix(3))
            var prints: [FeaturePrintObservation] = []
            for idx in sampleMembers {
                if let crop = makeOrientedObjectCrop(image, box: items[idx].box),
                   let obs = try? await GenerateImageFeaturePrintRequest().perform(on: crop)
                {
                    prints.append(obs)
                }
            }
            if let first = prints.first { repPrints[g] = first }
            if prints.count >= 2 {
                for i in 0..<prints.count {
                    for j in (i + 1)..<prints.count {
                        if let d = try? prints[i].distance(to: prints[j]) {
                            intraDistances.append(d)
                        }
                    }
                }
            }
        }

        if !intraDistances.isEmpty {
            let sortedIntra = intraDistances.sorted()
            let med = sortedIntra[sortedIntra.count / 2]
            fpStats.intraGroupDistanceMedian = med

            var parent = Array(groups.indices)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { r = parent[r] }
                return r
            }
            for a in groups.indices {
                guard let pA = repPrints[a] else { continue }
                let sA = groupShort(groups[a])
                for b in (a + 1)..<groups.count {
                    guard let pB = repPrints[b] else { continue }
                    let sB = groupShort(groups[b])
                    guard abs(sA - sB) <= 0.15 * max(sA, sB),
                          let d = try? pA.distance(to: pB),
                          d <= med
                    else { continue }
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[rb] = ra }
                }
            }
            var bucketed: [Int: [[Int]]] = [:]
            var bucketOrder: [Int] = []
            for g in groups.indices {
                let r = find(g)
                if bucketed[r] == nil { bucketOrder.append(r) }
                bucketed[r, default: []].append(groups[g])
            }
            var nextGroups: [[Int]] = []
            var extraMerges = 0
            for r in bucketOrder {
                let parts = bucketed[r]!
                let combined = parts.flatMap { $0 }
                nextGroups.append(combined)
                if parts.count > 1 {
                    extraMerges += parts.count - 1
                    ruleCounts["feature-print-merge", default: 0] += 1
                    for idx in combined where items[idx].fixRule == nil {
                        items[idx].fixRule = "feature-print-merge"
                        items[idx].fixReason = "feature-print distance within intra-group median (\(String(format: "%.3f", med)))"
                    }
                }
            }
            groups = nextGroups
            fpStats.groupsAfter = groups.count
            fpStats.extraMerges = extraMerges
            fpStats.mergedMoreThanModule = extraMerges > 0
        }
    }

    if enableModule || fpStats.extraMerges > 0 {
        var multiGroupNumber = 0
        for members in groups {
            if members.count > 1 {
                multiGroupNumber += 1
                let label = "label this group once (group \(multiGroupNumber), \(members.count) shapes)"
                for idx in members { items[idx].reason = label }
            } else {
                items[members[0]].reason = "unique shape, label it"
            }
        }
    }

    return fpStats
}
