import Foundation

/// 말풍선과 상태 칩에 어디까지 보여줄지 (설계서 §7.4)
public enum PrivacyLevel: String, Hashable, Sendable, CaseIterable {
    /// 파일명, 명령어까지 표시 (민감 문자열은 항상 가림)
    case detailed
    /// 툴 종류만 표시 ("파일 편집 중")
    case summary
    /// 아이콘과 표정만
    case hidden
}

/// 말풍선 대사 모음. 같은 상황에서도 여러 줄 중 무작위로 고릅니다.
public struct DialogueBook: Sendable {
    public private(set) var lines: [String: [String]]

    public init(lines: [String: [String]]) {
        self.lines = lines
    }

    /// 패키지에 들어 있는 한국어 대사
    public static let korean: DialogueBook = {
        guard let url = Bundle.module.url(forResource: "dialogue.ko", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let book = try? DialogueBook(json: data)
        else {
            preconditionFailure("dialogue.ko.json을 읽을 수 없습니다")
        }
        return book
    }()

    public init(json data: Data) throws {
        var lines: [String: [String]] = [:]
        for entry in try JSONValue.parse(data).objectValue?.entries ?? [] where !entry.key.hasPrefix("_") {
            lines[entry.key] = entry.value.arrayValue?.compactMap(\.stringValue) ?? []
        }
        self.init(lines: lines)
    }

    /// 자리표시자가 모두 채워지는 줄 중 하나를 고릅니다. 고를 줄이 없으면 nil.
    /// 주어진 정보를 가장 많이 쓰는 줄을 우선합니다 ("RouterConfig 리뷰 부탁해요!"가 "이거 부탁해요!"보다 먼저).
    public func line(_ key: String, _ variables: [String: String] = [:], using rng: inout some RandomNumberGenerator) -> String? {
        let usable = (lines[key] ?? []).filter { Self.placeholders(in: $0).isSubset(of: Set(variables.keys)) }
        let richest = usable.map { Self.placeholders(in: $0).count }.max() ?? 0
        let candidates = usable.filter { Self.placeholders(in: $0).count == richest }
        guard let template = candidates.randomElement(using: &rng) else { return nil }
        var text = template
        for (name, value) in variables {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return text
    }

    static func placeholders(in template: String) -> Set<String> {
        Set(template.matches(of: /\{([a-z]+)\}/).map { String($0.1) })
    }
}
