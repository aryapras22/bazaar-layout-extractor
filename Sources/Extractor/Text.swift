import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Vision frequently returns Cyrillic homoglyphs for single-letter Latin booth labels and the digit 3.
let cyrillicLookalikes: [Character: Character] = [
    "\u{0410}": "A", "\u{0412}": "B", "\u{0421}": "C", "\u{0415}": "E", "\u{041D}": "H",
    "\u{041A}": "K", "\u{041E}": "O", "\u{0425}": "X", "\u{0417}": "3", "\u{041C}": "M", "\u{0420}": "P", "\u{0422}": "T", "\u{0406}": "I",
]

func foldLookalikes(_ s: String) -> String {
    String(s.map { cyrillicLookalikes[$0] ?? $0 })
}

func makeTextRequest() -> RecognizeTextRequest {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    return request
}

func readLabel(_ image: CGImage, in rect: CGRect) async throws -> String? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let crop = image.cropping(to: rect.insetBy(dx: 4, dy: 4).intersection(bounds)) else { return nil }
    // Vision reads text on a tile this small better when it is enlarged first.
    let small = min(crop.width, crop.height) < 40
    let readable = small ? upscaled(crop, by: 3) ?? crop : crop
    let first = try await makeTextRequest().perform(on: readable).max { $0.confidence < $1.confidence }?.transcript
    if let first, cleanLabel(first) != nil { return first }
    // A blurred or compressed tile reads as nothing at its own size. Vision is jumpy on crops this small,
    // so several enlarged and sharpened crops vote and the most common readable label wins.
    var votes: [String: (count: Int, raw: String)] = [:]
    for (factor, inset) in [(3, 3.0), (3, 4.0), (3, 2.0), (2, 3.0), (2, 4.0)] {
        guard let wide = image.cropping(to: rect.insetBy(dx: inset, dy: inset).intersection(bounds)),
              let sharp = sharpened(wide, by: factor) else { continue }
        for obs in try await makeTextRequest().perform(on: sharp) {
            if let label = cleanLabel(obs.transcript) { votes[label, default: (0, obs.transcript)].count += 1 }
        }
    }
    let best = votes.max { $0.value.count < $1.value.count }?.value.raw ?? first
    return best
}

func cleanLabel(_ raw: String) -> String? {
    var s = Array(foldLookalikes(raw.uppercased()).filter { !$0.isWhitespace })
    while let first = s.first, !first.isLetter && !first.isNumber { s.removeFirst() }
    while let last = s.last, !last.isLetter && !last.isNumber { s.removeLast() }
    guard let firstDigit = s.firstIndex(where: { $0.isNumber }), (1...3).contains(firstDigit) else { return nil }
    let head = s[..<firstDigit]
    guard head.allSatisfy({ $0.isLetter }) else { return nil }
    let tail = s[firstDigit...].map { c -> Character in
        switch c {
        case "I", "L", "|": return "1"
        case "O": return "0"
        default: return c
        }
    }
    guard (1...3).contains(tail.count), tail.allSatisfy({ $0.isNumber }) else { return nil }
    return String(head) + String(tail)
}

struct PageText {
    let transcript: String
    let confidence: Float
    let box: CGRect
}

/// Reads text over the content area only, with boxes returned in whole-image coordinates. Vision reads
/// very large pages badly (it saw rows of chairs as long digit strings), so a plan inside wide margins
/// must give it the same input as the plan alone.
func recognizePageText(
    _ request: RecognizeTextRequest, in image: CGImage, content: CGRect, minimumTextHeight: Double? = nil
) async throws -> [PageText] {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let area = (content.isEmpty ? bounds : content.insetBy(dx: -24, dy: -24).intersection(bounds))
    guard let crop = image.cropping(to: area) else { return [] }
    var request = request
    if let minimumTextHeight {
        request.minimumTextHeightFraction = Float(max(0.001, minimumTextHeight / Double(crop.height)))
    }
    let size = CGSize(width: crop.width, height: crop.height)
    return try await request.perform(on: crop).map { observation in
        var box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        box.origin.x += area.minX
        box.origin.y += area.minY
        return PageText(transcript: observation.transcript, confidence: observation.confidence, box: box)
    }
}
