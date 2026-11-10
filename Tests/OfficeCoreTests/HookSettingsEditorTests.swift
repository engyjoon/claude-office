import Foundation
import Testing

@testable import OfficeCore

@Suite("settings.json 훅 설치기")
struct HookSettingsEditorTests {
    let command = "/Users/demo/.claude/hooks/claude-office.sh"
    let original = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say done"
                  }
                ]
              }
            ]
          },
          "theme": "dark"
        }
        """

    @Test("기존 훅과 키 순서를 지키며 설치한다")
    func install() throws {
        let settings = try JSONValue.parse(original)
        let installed = try HookSettingsEditor.install(into: settings, command: command, events: ["Stop", "PreToolUse"])
        #expect(installed.objectValue?.keys == ["model", "hooks", "theme"])
        let stop = try #require(installed["hooks"]?["Stop"]?.arrayValue)
        #expect(stop.count == 2)
        #expect(stop[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue == "say done")
        #expect(stop[1]["hooks"]?.arrayValue?.first?["command"]?.stringValue == command)
        #expect(stop[1]["matcher"] == nil)
        #expect(installed["hooks"]?["PreToolUse"]?.arrayValue?.first?["matcher"]?.stringValue == "*")
        #expect(HookSettingsEditor.installedEvents(in: installed) == ["Stop", "PreToolUse"])
    }

    @Test("여러 번 설치해도 결과가 같다")
    func idempotent() throws {
        let settings = try JSONValue.parse(original)
        let once = try HookSettingsEditor.install(into: settings, command: command, events: HookSettingsEditor.baseEvents)
        let twice = try HookSettingsEditor.install(into: once, command: command, events: HookSettingsEditor.baseEvents)
        #expect(once == twice)
    }

    @Test("제거하면 원래 설정으로 돌아간다")
    func uninstall() throws {
        let settings = try JSONValue.parse(original)
        let installed = try HookSettingsEditor.install(into: settings, command: command, events: HookSettingsEditor.baseEvents)
        let (restored, removed) = try HookSettingsEditor.uninstall(from: installed)
        #expect(removed == HookSettingsEditor.baseEvents.count)
        #expect(restored.serialized() == original)
    }

    @Test("훅이 하나도 없던 설정은 hooks 키까지 정리한다")
    func uninstallFromEmpty() throws {
        let installed = try HookSettingsEditor.install(into: ["model": "opus"], command: command, events: ["Stop"])
        let (restored, _) = try HookSettingsEditor.uninstall(from: installed)
        #expect(restored == ["model": "opus"])
    }

    @Test("형식이 이상한 설정은 건드리지 않고 오류를 낸다")
    func invalidShapes() {
        #expect(throws: HookSettingsError.rootIsNotObject) { try HookSettingsEditor.install(into: [1, 2], command: command, events: ["Stop"]) }
        #expect(throws: HookSettingsError.hooksIsNotObject) { try HookSettingsEditor.install(into: ["hooks": [1]], command: command, events: ["Stop"]) }
    }

    @Test("확장 이벤트는 확인된 버전 이상에서만 넣는다")
    func versionGate() {
        #expect(ClaudeVersion(parsing: "2.1.318 (Claude Code)") == ClaudeVersion(2, 1, 318))
        #expect(ClaudeVersion(parsing: "Claude Code v2.0.9") == ClaudeVersion(2, 0, 9))
        #expect(ClaudeVersion(parsing: "unknown") == nil)
        #expect(HookSettingsEditor.recommendedEvents(for: nil) == HookSettingsEditor.baseEvents)
        #expect(HookSettingsEditor.recommendedEvents(for: ClaudeVersion(2, 1, 0)) == HookSettingsEditor.baseEvents)
        #expect(HookSettingsEditor.recommendedEvents(for: ClaudeVersion(2, 1, 318)).contains("SubagentStart"))
        #expect(HookSettingsEditor.recommendedEvents(for: ClaudeVersion(3, 0, 0)).contains("PermissionRequest"))
    }
}

@Suite("에이전트 정의 파일")
struct AgentDefinitionTests {
    @Test("frontmatter에서 이름과 설명을 읽는다")
    func parse() {
        let markdown = """
            ---
            name: code-reviewer
            description: "코드 리뷰 담당. PR 전에 사용"
            tools: Read, Grep
            model: sonnet
            ---
            당신은 꼼꼼한 리뷰어입니다.
            """
        #expect(AgentDefinition.parse(markdown: markdown) == AgentDefinition(name: "code-reviewer", description: "코드 리뷰 담당. PR 전에 사용", model: "sonnet"))
    }

    @Test("frontmatter가 없거나 이름이 없으면 nil")
    func missing() {
        #expect(AgentDefinition.parse(markdown: "# 제목\n본문") == nil)
        #expect(AgentDefinition.parse(markdown: "---\ndescription: x\n---\n") == nil)
    }

    @Test("블록 값(|, >)과 들여 쓴 이어지는 줄, 큰따옴표의 \\n을 읽는다")
    func multiline() {
        let block = "---\nname: a\ndescription: |\n  첫 줄\n  둘째 줄\nmodel: opus\n---\n"
        #expect(AgentDefinition.parse(markdown: block) == AgentDefinition(name: "a", description: "첫 줄\n둘째 줄", model: "opus"))
        let folded = "---\nname: b\ndescription: >-\n  하나\n  둘\n---\n"
        #expect(AgentDefinition.parse(markdown: folded)?.description == "하나 둘")
        let continued = "---\nname: c\ndescription: 앞부분\n  뒷부분\ntools: Read\n---\n"
        #expect(AgentDefinition.parse(markdown: continued)?.description == "앞부분 뒷부분")
        let escaped = "---\nname: d\ndescription: \"설명\\n<example>예</example>\"\n---\n"
        #expect(AgentDefinition.parse(markdown: escaped)?.description == "설명\n<example>예</example>")
    }

    @Test("카드용 설명은 태그 블록 앞까지, 공백을 하나로 줄인다")
    func summary() {
        #expect(AgentDefinition(name: "a", description: "리뷰  담당.\n PR 전에 사용\n<example>긴 예시</example>").summary == "리뷰 담당. PR 전에 사용")
        #expect(AgentDefinition(name: "a", description: "<example>예시만</example>").summary == nil)
        #expect(AgentDefinition(name: "a").summary == nil)
    }
}
