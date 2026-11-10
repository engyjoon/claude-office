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
    ///
    /// 값이 `|`·`>`(블록)이거나 다음 줄로 이어지면(들여 쓴 줄) 이어 붙입니다. 큰따옴표 값의 `\n`은 줄바꿈으로 바꿉니다.
    public static func parse(markdown: String) -> AgentDefinition? {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        var current: (key: String, lines: [String], folded: Bool)?
        func finish() {
            guard let field = current else { return }
            fields[field.key] = field.lines.joined(separator: field.folded ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            current = nil
        }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                // 앞 값이 이어지는 줄
                current?.lines.append(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            finish()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if ["|", "|-", "|+", ">", ">-", ">+"].contains(value) {
                current = (key, [], value.hasPrefix(">"))
                continue
            }
            if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
                if first == "\"" { value = value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"") }
            }
            current = (key, [value], true)
        }
        finish()
        guard let name = fields["name"], !name.isEmpty else { return nil }
        return AgentDefinition(
            name: name,
            description: fields["description"].flatMap { $0.isEmpty ? nil : $0 },
            model: fields["model"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// 신원 카드에 보여 줄 설명: `<example>` 같은 태그 블록 앞까지만, 줄바꿈·연속 공백은 공백 하나로. 없으면 nil.
    public var summary: String? {
        guard var text = description else { return nil }
        if let tag = text.range(of: #"<[A-Za-z_][A-Za-z0-9_-]*>"#, options: .regularExpression) {
            text = String(text[..<tag.lowerBound])
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
