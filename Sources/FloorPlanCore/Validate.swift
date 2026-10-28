import Foundation

public struct Issue: Equatable {
    public var check: String
    public var index: Int
    public var message: String
}

// Check "id-pattern": an item that claims to be fine must carry its class prefix followed by digits.
public func idPatternIssues(_ items: [LayoutItem]) -> [Issue] {
    var issues: [Issue] = []
    for cls in numberedClasses(items) {
        for i in cls.indices where !items[i].needsReview {
            guard let id = items[i].id else { continue }
            if parseID(id)?.prefix != cls.prefix {
                issues.append(Issue(check: "id-pattern", index: i,
                                    message: "\(cls.name): id \"\(id)\" does not match \(cls.prefix) + digits but needs_review is false"))
            }
        }
    }
    return issues
}
