import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum Layer: String, CaseIterable, Comparable, Sendable {
    case booth, wall, door, seat, misc

    /// Walls own columns, because a column is part of the structure; furniture, round tables included, is seats.
    static func of(_ item: Item) -> Layer {
        switch item.cls {
        case "wall", "pillar": return .wall
        case "door", "opening": return .door
        case "object": return .seat
        case "misc": return .misc
        default: return .booth
        }
    }

    var file: String {
        switch self {
        case .booth: return "booths.json"
        case .wall: return "walls.json"
        case .door: return "doors.json"
        case .seat: return "seats.json"
        case .misc: return "misc.json"
        }
    }

    public static func < (a: Layer, b: Layer) -> Bool {
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
    let columns = columnLayer(scan, bands: walls.bands)
    let doors = doorLayer(scan, walls: walls)
    let swings = doors.filter { $0.cls == "door" }.map(\.rect)
    // Columns are not read as items, but the seat layer still needs their ink out of the way. The arcs of a swing
    // symbol look like a chair group to the seat layer, so objects inside a swing box are dropped.
    let seats = seatLayer(scan, hollow: columns.hollow).filter { item in
        item.cls != "object" || !swings.contains { $0.insetBy(dx: -2, dy: -2).contains(item.rect) }
    }
    return OutsideLayers(walls: walls.items, columns: [], doors: doors, seats: seats)
}
