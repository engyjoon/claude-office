import Foundation
import Testing

@testable import OfficeCore

@Suite("JSONValue")
struct JSONValueTests {
    @Test("키 순서와 숫자 표기를 보존한 채 다시 직렬화한다")
    func roundTripPreservesOrderAndNumbers() throws {
        let text = """
            {
              "zeta": 1,
              "alpha": [
                true,
                false,
                null,
                1.50,
                -2e3
              ],
              "hooks": {}
            }
            """
        let value = try JSONValue.parse(text)
        #expect(value.objectValue?.keys == ["zeta", "alpha", "hooks"])
        #expect(value.serialized() == text)
    }

    @Test("유니코드 이스케이프와 서로게이트 쌍, 한글을 읽는다")
    func unicode() throws {
        let value = try JSONValue.parse(#"{"a":"é😀 한글\n"}"#)
        #expect(value["a"]?.stringValue == "é😀 한글\n")
        #expect(value.serialized(pretty: false) == #"{"a":"é😀 한글\n"}"#)
    }

    @Test("잘못된 JSON은 위치와 함께 오류를 낸다", arguments: ["{", "[1,]", "{\"a\" 1}", "tru", "\"abc", "{} x", "01x"])
    func invalid(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
    }

    @Test("접근자")
    func accessors() throws {
        let value = try JSONValue.parse(#"{"n": 42, "f": 1.5, "s": "x", "b": true, "o": {"k": []}}"#)
        #expect(value["n"]?.intValue == 42)
        #expect(value["f"]?.doubleValue == 1.5)
        #expect(value["s"]?.stringValue == "x")
        #expect(value["b"]?.boolValue == true)
        #expect(value["o"]?["k"]?.arrayValue?.isEmpty == true)
        #expect(value["missing"] == nil)
    }

    @Test("JSONObject는 nil 대입으로 키를 지운다")
    func objectRemoval() {
        var object = JSONObject([("a", 1), ("b", 2)])
        object["a"] = nil
        object["c"] = 3
        #expect(object.keys == ["b", "c"])
    }
}
