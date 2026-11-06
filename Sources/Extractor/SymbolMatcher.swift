import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct MatchResult: Sendable {
    public let symbolClass: String
    public let score: Double

    public init(symbolClass: String, score: Double) {
        self.symbolClass = symbolClass
        self.score = score
    }
}

public actor SymbolMatcher {
    private let legend: SymbolLegend
    private var cachedPrints: [String: FeaturePrintObservation] = [:]

    public init(legend: SymbolLegend) {
        self.legend = legend
    }

    private func printForEntry(_ entry: SymbolEntry) async -> FeaturePrintObservation? {
        if let existing = cachedPrints[entry.id] { return existing }
        guard let img = legend.image(for: entry),
              let obs = try? await GenerateImageFeaturePrintRequest().perform(on: img) else {
            return nil
        }
        cachedPrints[entry.id] = obs
        return obs
    }

    public func match(
        crop: CGImage,
        candidates: [SymbolEntry],
        candidateColor: [Int]? = nil,
        threshold: Double = 0.50
    ) async -> MatchResult? {
        guard !candidates.isEmpty else { return nil }
        guard let cropObs = try? await GenerateImageFeaturePrintRequest().perform(on: crop) else {
            return nil
        }

        var bestEntry: SymbolEntry?
        var bestScore: Double = -1.0

        for entry in candidates {
            guard let entryObs = await printForEntry(entry) else { continue }
            guard let distFloat = try? cropObs.distance(to: entryObs) else { continue }
            let dist = Double(distFloat)
            let shapeScore = max(0.0, 1.0 - dist)

            if let entryColor = entry.color, let candidateColor {
                let rDiff = Double(entryColor[0] - candidateColor[0])
                let gDiff = Double(entryColor[1] - candidateColor[1])
                let bDiff = Double(entryColor[2] - candidateColor[2])
                let colorDist = (rDiff * rDiff + gDiff * gDiff + bDiff * bDiff).squareRoot()
                if colorDist > 65.0 {
                    continue
                }
            }

            if shapeScore > bestScore {
                bestScore = shapeScore
                bestEntry = entry
            }
        }

        guard let bestEntry, bestScore >= threshold else { return nil }
        return MatchResult(symbolClass: bestEntry.id, score: bestScore)
    }
}
