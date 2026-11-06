import Foundation

/// 키 순서를 보존하는 JSON 객체.
///
/// `~/.claude/settings.json`을 고칠 때 사용자가 정한 키 순서를 바꾸지 않기 위해
/// Foundation의 `JSONSerialization` 대신 직접 파싱합니다.
public struct JSONObject: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var key: String
        public var value: JSONValue
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public var keys: [String] { entries.map(\.key) }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public subscript(key: String) -> JSONValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    entries[index].value = newValue
                } else {
                    entries.remove(at: index)
                }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }
}

/// 훅 페이로드와 설정 파일을 다루는 최소한의 JSON 값.
/// 숫자는 원래 표기를 그대로 보존합니다 (`1`이 `1.0`으로 바뀌지 않도록).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - 접근자

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let text) = self else { return nil }
        return Int(text) ?? Double(text).flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - 리터럴 (테스트와 설정 생성용)

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(String(value)) }
    public init(floatLiteral value: Double) { self = .number(String(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - 파싱

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "JSON 파싱 오류 (위치 \(offset)): \(message)" }
}

extension JSONValue {
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data))
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        // UTF-8 BOM 무시
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            self.bytes = Array(bytes.dropFirst(3))
        } else {
            self.bytes = bytes
        }
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw error("문서 끝에 불필요한 내용이 있습니다") }
        return value
    }

    func error(_ message: String) -> JSONParseError {
        JSONParseError(message: message, offset: index)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < 256 else { throw error("중첩이 너무 깊습니다") }
        guard index < bytes.count else { throw error("값이 필요합니다") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("예상하지 못한 문자입니다")
        }
    }

    mutating func expectLiteral(_ literal: String) throws {
        let utf8 = Array(literal.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
            throw error("\(literal)이(가) 필요합니다")
        }
        index += utf8.count
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("키 문자열이 필요합니다") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("':'이 필요합니다") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard index < bytes.count else { throw error("객체가 닫히지 않았습니다") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw error("',' 또는 '}'가 필요합니다")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error("배열이 닫히지 않았습니다") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
            throw error("',' 또는 ']'가 필요합니다")
        }
    }

    mutating func parseString() throws -> String {
        index += 1  // 여는 따옴표
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error("이스케이프가 끝나지 않았습니다") }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error("알 수 없는 이스케이프입니다")
                }
            case 0x00..<0x20:
                throw error("문자열 안에 제어 문자가 있습니다")
            default:
                buffer.append(byte)
                index += 1
            }
        }
        throw error("문자열이 닫히지 않았습니다")
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
            let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw error("\\u 뒤에 16진수 4자리가 필요합니다") }
        index += 4
        return value
    }

    mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try parseHex4()
        if (0xD800...0xDBFF).contains(first) {
            // 서로게이트 쌍
            if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                index += 2
                let second = try parseHex4()
                if (0xDC00...0xDFFF).contains(second) {
                    let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Unicode.Scalar(combined) ?? "\u{FFFD}"
                }
            }
            return "\u{FFFD}"
        }
        return Unicode.Scalar(first) ?? "\u{FFFD}"
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            let isNumberByte =
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e")
                || byte == UInt8(ascii: "E")
            guard isNumberByte else { break }
            index += 1
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard Double(text) != nil else {
            index = start
            throw error("숫자 형식이 올바르지 않습니다")
        }
        return .number(text)
    }
}

// MARK: - 직렬화

extension JSONValue {
    /// Claude Code가 settings.json을 쓰는 형식과 같은 2칸 들여쓰기로 직렬화합니다.
    public func serialized(pretty: Bool = true) -> String {
        var output = ""
        write(into: &output, level: 0, pretty: pretty)
        return output
    }

    private func write(into output: inout String, level: Int, pretty: Bool) {
        let indent = pretty ? String(repeating: "  ", count: level + 1) : ""
        let closingIndent = pretty ? String(repeating: "  ", count: level) : ""
        let newline = pretty ? "\n" : ""
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let text): output += text
        case .string(let value): output += Self.quoted(value)
        case .array(let values):
            guard !values.isEmpty else { output += "[]"; return }
            output += "[" + newline
            for (offset, value) in values.enumerated() {
                output += indent
                value.write(into: &output, level: level + 1, pretty: pretty)
                if offset < values.count - 1 { output += "," }
                output += newline
            }
            output += closingIndent + "]"
        case .object(let object):
            guard !object.isEmpty else { output += "{}"; return }
            output += "{" + newline
            for (offset, entry) in object.entries.enumerated() {
                output += indent + Self.quoted(entry.key) + (pretty ? ": " : ":")
                entry.value.write(into: &output, level: level + 1, pretty: pretty)
                if offset < object.count - 1 { output += "," }
                output += newline
            }
            output += closingIndent + "}"
        }
    }

    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case let s where s.value < 0x20:
                result += String(format: "\\u%04x", s.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
