import Foundation
import Testing

@testable import OfficeCore

@Suite("툴 분류와 민감 정보 가리기")
struct ToolCatalogTests {
    @Test(
        "툴 이름으로 분류한다",
        arguments: [
            ("Read", ToolCategory.read), ("Grep", .read), ("Glob", .read), ("Edit", .write), ("Write", .write),
            ("Bash", .shell), ("WebSearch", .web), ("WebFetch", .web), ("TodoWrite", .plan), ("Agent", .delegate),
            ("Task", .delegate), ("mcp__github__create_issue", .mcp), ("Something", .other),
        ])
    func categories(_ name: String, _ category: ToolCategory) {
        #expect(ToolCatalog.category(for: name) == category)
    }

    @Test("입력에서 보여줄 대상을 뽑는다")
    func subjects() {
        func subject(_ name: String, _ input: JSONValue) -> String? {
            ToolCatalog.makeCall(name: name, input: input, id: nil).subject
        }
        #expect(subject("Read", ["file_path": "/a/b/RouterConfig.java"]) == "RouterConfig.java")
        #expect(subject("Bash", ["command": "npm   test\n--watch"]) == "npm test")
        #expect(subject("WebFetch", ["url": "https://developer.apple.com/documentation"]) == "developer.apple.com")
        #expect(subject("Grep", ["pattern": "TODO"]) == "\"TODO\"")
        #expect(subject("Agent", ["description": "RouterConfig 리뷰", "subagent_type": "code-reviewer"]) == "RouterConfig 리뷰")
        #expect(subject("TodoWrite", ["todos": [1, 2, 3]]) == "할 일 3개")
        #expect(subject("mcp__github__create_issue", [:]) == nil)  // MCP 문구는 MCPNames (M6(5))
        #expect(subject("Edit", [:]) == nil)
    }

    @Test("긴 명령은 줄인다")
    func truncation() {
        let call = ToolCatalog.makeCall(name: "Bash", input: ["command": .string(String(repeating: "a ", count: 60))], id: nil)
        #expect(call.subject!.count <= 40)
        #expect(call.subject!.hasSuffix("…"))
    }

    @Test(
        "비밀번호와 토큰처럼 보이는 값을 가린다",
        arguments: [
            ("mysql --password=hunter2 db", "mysql --password=<가림> db"),
            ("export API_KEY=abc123", "export API_KEY=<가림>"),
            ("curl -H 'Authorization: Bearer xyz.abc'", "curl -H 'Authorization: Bearer <가림>"),
            ("git clone https://me:pw@github.com/x", "git clone https://<가림>@github.com/x"),
            ("echo sk-ant-api03-abcdefgh", "echo <가림>"),
            ("token: 'my secret'", "token: <가림>"),
            ("git show 4f2a9c8e1b7d6a5c4f3e2d1c0b9a8f7e6d5c4b3a", "git show <가림>"),
        ])
    func redaction(_ input: String, _ expected: String) {
        #expect(Redactor.redact(input) == expected)
    }

    @Test("평범한 명령과 경로는 그대로 둔다", arguments: ["git status", "npm test -- --watch=false", "cat /Users/demo/work/a-sdn-portal/src/main/java/com/example/RouterConfiguration.java"])
    func noFalsePositive(_ input: String) {
        #expect(Redactor.redact(input) == input)
    }
}
