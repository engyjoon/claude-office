import Foundation

/// `.claude/agents/*.md`의 frontmatter에서 읽은 직접 정의한 에이전트 (설계서 §4.5)
public struct AgentDefinition: Hashable, Sendable {
    public var name: String
    public var description: String?
    public var model: String?

    public init(name: String, description: String? = nil, model: String? = nil) {
        self.name = name
        self.description = description
        self.model = model
    }

    /// `---`로 둘러싼 frontmatter의 `key: value` 줄만 읽습니다. 이름이 없으면 nil.
    public static func parse(markdown: String) -> AgentDefinition? {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        guard let name = fields["name"], !name.isEmpty else { return nil }
        return AgentDefinition(
            name: name,
            description: fields["description"].flatMap { $0.isEmpty ? nil : $0 },
            model: fields["model"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
