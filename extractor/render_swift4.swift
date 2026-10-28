import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LayoutImage: Decodable {
    let width: Int
    let height: Int
}

struct LayoutItem: Decodable {
    let `class`: String
    let box: [Int]
    let fill_rgb: [Int]?
    let polygon: [[Double]]?
    let id: String?
    let text: String?
    let suggested_id: String?
}

struct LayoutFile: Decodable {
    let image: LayoutImage
    let items: [LayoutItem]
}

enum SuggestionMode {
    case automatic
    case forceSuggested
    case noSuggested
}

@main
struct RenderSwift4 {
    static let outsideStyles: [String: (color: CGColor, lineWidth: CGFloat, fill: Bool)] = [
        "wall": (CGColor(red: 0, green: 0, blue: 0, alpha: 1), 3, false),
        "door": (CGColor(red: 0, green: 160.0 / 255.0, blue: 0, alpha: 1), 4, false),
        "pillar": (CGColor(red: 90.0 / 255.0, green: 90.0 / 255.0, blue: 90.0 / 255.0, alpha: 1), 0, true),
        "object": (CGColor(red: 1, green: 140.0 / 255.0, blue: 0, alpha: 1), 2, false)
    ]

    static func main() throws {
        var paths: [String] = []
        var outOverride: String?
        var gridOverride: Int?
        var mode: SuggestionMode = .automatic
        var showReport = false

        var idx = 1
        let args = CommandLine.arguments
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--out":
                idx += 1
                if idx < args.count { outOverride = args[idx] }
            case "--grid":
                idx += 1
                if idx < args.count { gridOverride = Int(args[idx]) }
            case "--suggested":
                mode = .forceSuggested
            case "--no-suggested":
                mode = .noSuggested
            case "--report":
                showReport = true
            case "-h", "--help":
                printUsage()
                return
            default:
                if !arg.hasPrefix("-") {
                    paths.append(arg)
                }
            }
            idx += 1
        }

        if paths.isEmpty {
            let defaults = ["output/swift4/plan1", "output/swift4/plan2", "output/swift4/plan3"]
            let existing = defaults.filter { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("layout.json")) }
            if existing.isEmpty {
                printUsage()
                return
            }
            paths = existing
        }

        for path in paths {
            try renderPath(path, outOverride: paths.count == 1 ? outOverride : nil, gridOverride: gridOverride, mode: mode, showReport: showReport)
        }
    }

    static func printUsage() {
        print("Usage: render_swift4 <layout.json | out_dir>... [--out render.png] [--grid px] [--suggested] [--no-suggested] [--report]")
    }

    static func renderPath(_ inputPath: String, outOverride: String?, gridOverride: Int?, mode: SuggestionMode, showReport: Bool) throws {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: inputPath, isDirectory: &isDir) else {
            fputs("Error: path not found: \(inputPath)\n", stderr)
            return
        }

        let jsonURL: URL
        let outURL: URL

        if isDir.boolValue {
            jsonURL = URL(fileURLWithPath: inputPath).appendingPathComponent("layout.json")
            if let outOverride = outOverride {
                outURL = URL(fileURLWithPath: outOverride)
            } else {
                outURL = URL(fileURLWithPath: inputPath).appendingPathComponent("render.png")
            }
        } else {
            jsonURL = URL(fileURLWithPath: inputPath)
            if let outOverride = outOverride {
                outURL = URL(fileURLWithPath: outOverride)
            } else {
                outURL = jsonURL.deletingLastPathComponent().appendingPathComponent("render.png")
            }
        }

        guard fileManager.fileExists(atPath: jsonURL.path) else {
            fputs("Error: layout file not found at \(jsonURL.path)\n", stderr)
            return
        }

        let data = try Data(contentsOf: jsonURL)
        let layout = try JSONDecoder().decode(LayoutFile.self, from: data)

        let W = layout.image.width
        let H = layout.image.height

        let gridStep: Int
        if let g = gridOverride {
            gridStep = g
        } else if inputPath.contains("plan2") {
            gridStep = 60
        } else {
            gridStep = 33
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: W,
                  height: H,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            fputs("Error: failed to create CGContext of size \(W)x\(H)\n", stderr)
            return
        }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        ctx.setAllowsAntialiasing(false)
        let maxDim = max(W, H)
        for (i, pos) in stride(from: 0, to: maxDim, by: gridStep).enumerated() {
            let shade: CGFloat = (i % 5 == 0) ? (170.0 / 255.0) : (225.0 / 255.0)
            ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
            if pos < W {
                ctx.fill(CGRect(x: pos, y: 0, width: 1, height: H))
            }
            if pos < H {
                ctx.fill(CGRect(x: 0, y: H - pos - 1, width: W, height: 1))
            }
        }
        ctx.setAllowsAntialiasing(true)

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil)
        var suggestionCount = 0

        for it in layout.items {
            let x = it.box[0], y = it.box[1], w = it.box[2], h = it.box[3]
            let rect = CGRect(x: CGFloat(x), y: CGFloat(H - y - h), width: CGFloat(w), height: CGFloat(h))

            if let style = outsideStyles[it.class] {
                if style.fill {
                    ctx.setFillColor(style.color)
                    if let poly = it.polygon, poly.count >= 3 {
                        let path = CGMutablePath()
                        path.move(to: CGPoint(x: CGFloat(poly[0][0]), y: CGFloat(H) - CGFloat(poly[0][1])))
                        for pt in poly.dropFirst() {
                            path.addLine(to: CGPoint(x: CGFloat(pt[0]), y: CGFloat(H) - CGFloat(pt[1])))
                        }
                        path.closeSubpath()
                        ctx.addPath(path)
                        ctx.fillPath()
                    } else {
                        ctx.fill(rect)
                    }
                } else {
                    ctx.setStrokeColor(style.color)
                    ctx.setLineWidth(style.lineWidth)
                    if let poly = it.polygon, poly.count >= 3 {
                        let path = CGMutablePath()
                        path.move(to: CGPoint(x: CGFloat(poly[0][0]), y: CGFloat(H) - CGFloat(poly[0][1])))
                        for pt in poly.dropFirst() {
                            path.addLine(to: CGPoint(x: CGFloat(pt[0]), y: CGFloat(H) - CGFloat(pt[1])))
                        }
                        path.closeSubpath()
                        ctx.addPath(path)
                        ctx.strokePath()
                    } else {
                        ctx.stroke(rect)
                    }
                }
                continue
            }

            let outline: CGColor
            if let rgb = it.fill_rgb, rgb.count >= 3 {
                let r = rgb[0], g = rgb[1], b = rgb[2]
                if r > 235 && g > 235 && b > 235 {
                    outline = CGColor(red: 160.0 / 255.0, green: 160.0 / 255.0, blue: 160.0 / 255.0, alpha: 1)
                } else {
                    outline = CGColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1)
                }
            } else {
                outline = CGColor(red: 160.0 / 255.0, green: 160.0 / 255.0, blue: 160.0 / 255.0, alpha: 1)
            }

            ctx.setStrokeColor(outline)
            ctx.setLineWidth(3)

            if let poly = it.polygon, poly.count >= 3 {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: CGFloat(poly[0][0]), y: CGFloat(H) - CGFloat(poly[0][1])))
                for pt in poly.dropFirst() {
                    path.addLine(to: CGPoint(x: CGFloat(pt[0]), y: CGFloat(H) - CGFloat(pt[1])))
                }
                path.closeSubpath()
                ctx.addPath(path)
                ctx.strokePath()
            } else {
                ctx.stroke(rect)
            }

            let labelText: String
            let textColor: CGColor

            switch mode {
            case .forceSuggested:
                if let sug = it.suggested_id {
                    labelText = sug
                    textColor = CGColor(red: 30.0 / 255.0, green: 100.0 / 255.0, blue: 220.0 / 255.0, alpha: 1)
                    suggestionCount += 1
                } else if let id = it.id {
                    labelText = id
                    textColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                } else {
                    labelText = "?"
                    textColor = CGColor(red: 220.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
                }
            case .noSuggested:
                if let id = it.id {
                    labelText = id
                    textColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                } else {
                    labelText = "?"
                    textColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                }
            case .automatic:
                if let id = it.id {
                    labelText = id
                    textColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                } else if let sug = it.suggested_id {
                    labelText = sug
                    textColor = CGColor(red: 30.0 / 255.0, green: 100.0 / 255.0, blue: 220.0 / 255.0, alpha: 1)
                    suggestionCount += 1
                } else {
                    labelText = "?"
                    textColor = CGColor(red: 220.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
                }
            }

            let attr: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): textColor
            ]
            let attrStr = NSAttributedString(string: labelText, attributes: attr)
            let line = CTLineCreateWithAttributedString(attrStr)

            let textX = CGFloat(w <= 16 ? x + max(1, (w - 10) / 2) : x + 6)
            let textY = CGFloat(H) - CGFloat(y + h / 2 + 6)
            ctx.textPosition = CGPoint(x: textX, y: textY)
            CTLineDraw(line, ctx)
        }

        guard let img = ctx.makeImage() else {
            fputs("Error: makeImage failed\n", stderr)
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fputs("Error: could not create image destination at \(outURL.path)\n", stderr)
            return
        }

        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            fputs("Error: failed to write image to \(outURL.path)\n", stderr)
            return
        }

        print("Rendered \(outURL.path) (\(W)x\(H), grid \(gridStep)px, \(layout.items.count) items, \(suggestionCount) suggestions)")

        if showReport {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let rep = json?["report"],
               let repData = try? JSONSerialization.data(withJSONObject: rep, options: [.prettyPrinted, .sortedKeys]),
               let repStr = String(data: repData, encoding: .utf8) {
                print(repStr)
            }
        }
    }
}
