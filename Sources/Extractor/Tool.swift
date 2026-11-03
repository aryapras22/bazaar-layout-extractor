import Foundation

/// fp-extract: one plan in, one folder of layers out. The pipeline is the list below; each line is one stage of `PlanRun`.
public enum ExtractTool {
    public static func run(arguments: [String]) async throws {
        guard let opts = parseOptions(arguments) else {
            fputs(usage, stderr)
            exit(2)
        }
        let run = try await PlanRun.load(opts)
        let claimed = try await run.findBooths()
        await run.findOutside(claimed: claimed)
        try await run.readIds()
        await run.review()
        try run.write()
    }
}
