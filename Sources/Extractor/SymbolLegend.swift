import CoreGraphics
import Foundation
import ImageIO

public struct SymbolEntry: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let layer: String
    public let file: String
    public let color: [Int]?

    public init(id: String, name: String, layer: String, file: String, color: [Int]? = nil) {
        self.id = id
        self.name = name
        self.layer = layer
        self.file = file
        self.color = color
    }
}

public struct SymbolLegend: Sendable {
    public let entries: [SymbolEntry]
    public let directory: URL?

    public static let empty = SymbolLegend(entries: [], directory: nil)

    public init(entries: [SymbolEntry], directory: URL? = nil) {
        self.entries = entries
        self.directory = directory
    }

    public static func load(from url: URL) throws -> SymbolLegend {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        let jsonURL: URL
        let dirURL: URL

        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            jsonURL = url.appendingPathComponent("legends.json")
            dirURL = url
        } else {
            jsonURL = url
            dirURL = url.deletingLastPathComponent()
        }

        let data = try Data(contentsOf: jsonURL)
        let entries = try JSONDecoder().decode([SymbolEntry].self, from: data)
        return SymbolLegend(entries: entries, directory: dirURL)
    }

    public func entries(for layer: Layer) -> [SymbolEntry] {
        entries.filter { $0.layer == layer.rawValue }
    }

    public func image(for entry: SymbolEntry) -> CGImage? {
        guard let directory else { return nil }
        let imageURL = directory.appendingPathComponent(entry.file)
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }
}
