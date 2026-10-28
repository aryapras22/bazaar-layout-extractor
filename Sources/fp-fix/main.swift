import Foundation
import FloorPlanCore

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: fp-fix layout.json out.json\n", stderr)
    exit(2)
}

var layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let issues = idPatternIssues(layout.items)
let result = repair(layout.items, image: (layout.image.width, layout.image.height))
layout.items = result.items

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(layout).write(to: URL(fileURLWithPath: args[2]))

for issue in issues { print("[\(issue.check)] item \(issue.index): \(issue.message)") }
for change in result.changes { print("[\(change.rule)] \(change.message)") }
let counts = Dictionary(grouping: result.changes, by: \.rule).mapValues(\.count)
let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
print("\(issues.count) id-pattern issues; changes: \(summary.isEmpty ? "none" : summary)")
