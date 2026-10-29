import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Door layer: openings, meaning long gaps in the ink along a wall band.
func doorLayer(_ s: InkScan, walls: WallResult) -> [Item] {
    let (w, h, mx, rawInk) = (s.w, s.h, s.mx, s.rawInk)
    let (wallBands, fallback) = (walls.bands, walls.fallback)
    var items: [Item] = []

    let minGap = Int(0.03 * Double(mx))
    for band in wallBands {
        var cov = [Bool](repeating: false, count: band.hi - band.lo + 1)
        let crossLimit = band.horizontal ? h : w
        let cLo = max(0, band.c0 - 2), cHi = min(crossLimit - 1, band.c1 + 2)
        for a in band.lo...band.hi {
            for c in cLo...cHi where rawInk[band.horizontal ? c * w + a : a * w + c] {
                cov[a - band.lo] = true
                break
            }
        }
        for (a, b) in gaps(cov, minLen: minGap) {
            let rect = band.horizontal
                ? CGRect(x: band.lo + a, y: band.c0, width: b - a + 1, height: band.c1 - band.c0 + 1)
                : CGRect(x: band.c0, y: band.lo + a, width: band.c1 - band.c0 + 1, height: b - a + 1)
            items.append(outsideItem("door", rect, review: fallback, reason: fallback ? "wall is a single line" : nil))
        }
    }
    return items
}
