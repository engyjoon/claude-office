import Foundation
import Testing

@testable import OfficeCore

/// M4 표현: 위임·승인 대기·완료 보고에서 표정·제스처·아이콘·소리가 제대로 나오는지
@Suite("표현 (M4)")
struct ExpressionTests {
    let hook = Hook()
    let lead = AgentID("lead-1")

    @Test("승인되면 외침 풍선을 닫고 끄덕인 뒤, 같은 종류의 작업이어도 손 든 자세를 푼다")
    func approvalResolves() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"]), at: 8)
        h.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "npm test"]), at: 8.2)
        // 승인 후 같은 셸 작업이 이어집니다 (병렬 툴)
        let resumed = h.send(hook.tool("PreToolUse", "Bash", id: "b2", input: ["command": "npm run lint"]), at: 9)
        let actions = resumed.filter { $0.agent == lead }.map(\.action)
        #expect(actions.contains(.dismissBubble))
        #expect(actions.contains(.gesture(.nod)))
        #expect(actions.contains(.emote(nil)))
        // 마지막 자세는 손 들기가 아닙니다
        let lastPose = actions.compactMap { if case .pose(let pose) = $0 { pose } else { nil } }.last
        #expect(lastPose == .typing)
        #expect(actions.contains(.express(.focus)))
    }

    @Test("입력 대기: 뾰롱 소리와 함께 고개를 갸웃하고 ❓를 띄운다")
    func waitingForInput() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        let waiting = h.send(hook.make("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]), at: 8)
        #expect(waiting.sounds.contains(.inputWaiting))
        #expect(waiting.contains(Directive(lead, .gesture(.tilt))))
        #expect(waiting.contains(Directive(lead, .emote(.question))))
    }

    @Test("완료 보고: 팀원은 하이파이브와 띠링, 팀장은 하이파이브 뒤 엄지척과 ✨")
    func reportGestures() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        h.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "리뷰", "subagent_type": "code-reviewer"]), at: 1)
        h.send(hook.make("SubagentStart", ["agent_id": "x1", "agent_type": "code-reviewer"]), at: 1.2)
        let report = h.send(hook.make("SubagentStop", ["agent_id": "x1", "agent_type": "code-reviewer"]), at: 10)
        let leadActions = report.filter { $0.agent == lead }.map(\.action)
        let highFive = leadActions.firstIndex(of: .gesture(.highFive))
        let thumbs = leadActions.firstIndex(of: .gesture(.thumbsUp))
        #expect(highFive != nil && thumbs != nil && highFive! < thumbs!)
        #expect(leadActions.contains(.emote(.sparkle)))
        #expect(leadActions.contains(.express(.proud)))
        #expect(report.sounds.contains(.memberReport))
    }

    @Test("응답 완료: 기지개, 뿌듯한 표정, ✨, 띠리링")
    func turnDone() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        h.send(hook.make("UserPromptSubmit", ["prompt": "안녕"]), at: 5)
        let done = h.send(hook.make("Stop", ["stop_hook_active": false]), at: 8)
        #expect(done.contains(Directive(lead, .gesture(.stretch))))
        #expect(done.contains(Directive(lead, .express(.proud))))
        #expect(done.contains(Directive(lead, .emote(.sparkle))))
        #expect(done.sounds.contains(.turnComplete))
    }

    @Test("프롬프트의 💡는 일을 시작하면 내린다")
    func bulbClears() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        let prompt = h.send(hook.make("UserPromptSubmit", ["prompt": "안녕"]), at: 5)
        #expect(prompt.contains(Directive(lead, .emote(.bulb))))
        let work = h.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/a.swift"]), at: 6)
        #expect(work.contains(Directive(lead, .emote(nil))))
    }

    @Test("효과음 설정은 sound.enabled, sound.volume, sound.<항목>.enabled로 저장하고 다시 읽는다")
    func soundSettingsPersistence() throws {
        let defaults = try #require(UserDefaults(suiteName: "claude-office-test-\(UUID().uuidString)"))
        #expect(SoundSettings(defaults: defaults) == SoundSettings())  // 저장된 값이 없으면 기본값

        var settings = SoundSettings()
        settings.masterEnabled = false
        settings.volume = 0.8
        settings.set(.typing, enabled: true)
        settings.set(.door, enabled: false)
        settings.save(to: defaults)
        #expect(defaults.bool(forKey: "sound.typing.enabled"))
        #expect(defaults.double(forKey: "sound.volume") == 0.8)

        let loaded = SoundSettings(defaults: defaults)
        #expect(loaded == settings)
        #expect(SoundGroup.allCases.allSatisfy { !$0.detail.isEmpty })
    }
}
