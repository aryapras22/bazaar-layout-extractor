import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// What every outside layer starts from: the ink with booths and text removed, the text boxes, and the
/// long runs and thick or compact shapes that the wall, column and seat layers each read differently.
struct InkScan {
    let w: Int, h: Int, n: Int, mx: Int, scale: Double
    let rawInk: [Bool], ink: [Bool]
    let textBoxes: [CGRect], inText: [Bool]
    let longest: Int
    let hs: [Bool], vs: [Bool], thick: [Bool], compact: [Bool]
    let solidRegions: [Region]
    /// Slope of the page's near-horizontal and near-vertical lines; 0 when the page is straight.
    var tilt: (h: Double, v: Double) = (0, 0)
}

func scanInk(_ image: CGImage, _ px: Pixels, claimed: [Bool]) async -> InkScan {
    let (w, h) = (px.width, px.height)
    let n = w * h
    let mx = px.page
    let rawInk = inkMask(px)
    var ink = rawInk
    for i in 0..<n where claimed[i] { ink[i] = false }
    let scale = Double(mx) / 2000

    var textBoxes: [CGRect] = []
    if let found = try? await recognizePageText(makeTextRequest(), in: image, content: px.contentRect) {
        for o in found where o.confidence >= 0.5 {
            textBoxes.append(o.box.insetBy(dx: -3, dy: -3))
        }
    }
    var inText = [Bool](repeating: false, count: n)
    for box in textBoxes { fillRect(&inText, box, w: w, h: h, value: true) }
    for i in 0..<n where inText[i] { ink[i] = false }

    let longest = max(5, Int((0.025 * Double(mx)).rounded()))
    let tilt = (h: dominantTilt(rawInk, w: w, h: h, horizontal: true), v: dominantTilt(rawInk, w: w, h: h, horizontal: false))
    var hs = tiltedRuns(ink, w: w, h: h, minLen: longest, horizontal: true, tilt: tilt.h)
    var vs = tiltedRuns(ink, w: w, h: h, minLen: longest, horizontal: false, tilt: tilt.v)
    let k = max(7, Int((0.004 * Double(mx)).rounded()) | 1)
    let opened = morph(morph(ink, w: w, h: h, rx: k / 2, ry: k / 2, erode: true),
                       w: w, h: h, rx: k / 2, ry: k / 2, erode: false)
    var thick = [Bool](repeating: false, count: n)
    var compact = [Bool](repeating: false, count: n)
    var pillars: [Region] = []
    for reg in components(opened, w: w, h: h, eight: true) {
        let long = max(reg.width, reg.height), short = min(reg.width, reg.height)
        if (long >= 4 * short && long >= longest) || reg.fill < 0.5 {
            for i in reg.pixels { thick[i] = true }
        } else {
            for i in reg.pixels { compact[i] = true }
            if reg.area >= Int(100 * scale * scale) { pillars.append(reg) }
        }
    }
    let compactNear = morph(compact, w: w, h: h, rx: 2, ry: 2, erode: false)
    for i in 0..<n where compactNear[i] { hs[i] = false; vs[i] = false }
    return InkScan(
        w: w, h: h, n: n, mx: mx, scale: scale, rawInk: rawInk, ink: ink, textBoxes: textBoxes, inText: inText,
        longest: longest, hs: hs, vs: vs, thick: thick, compact: compact, solidRegions: pillars, tilt: tilt)
}
