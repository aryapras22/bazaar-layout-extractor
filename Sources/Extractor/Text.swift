import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Vision frequently returns Cyrillic homoglyphs for single-letter Latin booth labels and the digit 3.
let cyrillicLookalikes: [Character: Character] = [
    "\u{0410}": "A", "\u{0412}": "B", "\u{0421}": "C", "\u{0415}": "E", "\u{041D}": "H",
    "\u{041A}": "K", "\u{041E}": "O", "\u{0425}": "X", "\u{0417}": "3", "\u{041C}": "M", "\u{0420}": "P", "\u{0422}": "T",
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
    let found = try await makeTextRequest().perform(on: crop)
    return found.max { $0.confidence < $1.confidence }?.transcript
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
