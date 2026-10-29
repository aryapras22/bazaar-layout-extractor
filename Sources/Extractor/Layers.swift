import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum Layer: String, CaseIterable, Comparable {
    case booth, wall, door, seat

    /// Walls own columns, because a column is part of the structure; furniture, round tables included, is seats.
    static func of(_ item: Item) -> Layer {
        switch item.cls {
        case "wall", "pillar": return .wall
        case "door": return .door
        case "object": return .seat
        default: return .booth
        }
    }

    var file: String {
        switch self {
        case .booth: return "booths.json"
        case .wall: return "walls.json"
        case .door: return "doors.json"
        case .seat: return "seats.json"
        }
    }

    static func < (a: Layer, b: Layer) -> Bool {
        Layer.allCases.firstIndex(of: a)! < Layer.allCases.firstIndex(of: b)!
    }
}

struct LayerFile: Codable {
    var layer: String
    var image: ImageInfo
    var items: [Item]
}

struct OutsideLayers {
    var walls: [Item] = []
    var columns: [Item] = []
    var doors: [Item] = []
    var seats: [Item] = []
    /// The order the single pass used: walls, doors, columns, seats.
    var all: [Item] { walls + doors + columns + seats }
}

func outsideLayers(_ image: CGImage, _ px: Pixels, claimed: [Bool]) async -> OutsideLayers {
    let scan = await scanInk(image, px, claimed: claimed)
    let walls = wallLayer(scan)
    let columns = columnLayer(scan)
    return OutsideLayers(
        walls: walls.items,
        columns: columns.items,
        doors: doorLayer(scan, walls: walls),
        seats: seatLayer(scan, hollow: columns.hollow))
}
