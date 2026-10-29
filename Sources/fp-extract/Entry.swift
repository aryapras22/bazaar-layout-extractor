import Extractor

@main
struct Entry {
    static func main() async throws {
        try await ExtractTool.run(arguments: CommandLine.arguments)
    }
}
