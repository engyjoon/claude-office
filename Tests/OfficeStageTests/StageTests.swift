import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// 엔진과 무대를 함께 돌리는 하네스. 앱의 0.25초 tick과 매 프레임 update를 흉내 냅니다.
struct StageHarness {
    var engine = OfficeEngine(seed: 3)
    var stage = Stage()
    var now = 0.0
    var events: [StageEvent] = []
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    mutating func hook(_ json: String, at seconds: Double? = nil) {
        if let seconds { run(until: seconds) }
        let directives = (try? engine.handle(hookPayload: Data(json.utf8), at: epoch.addingTimeInterval(now))) ?? []
        stage.enqueue(directives)
    }

    mutating func run(until seconds: Double, frame: Double = 1.0 / 30) {
        var nextTick = (now / 0.25).rounded(.down) * 0.25 + 0.25
        while now < seconds {
            let step = min(frame, seconds - now)
            now += step
            stage.update(dt: step)
            if now >= nextTick {
                stage.enqueue(engine.tick(at: epoch.addingTimeInterval(now)))
                nextTick += 0.25
            }
            events += stage.drainEvents()
        }
    }

    func actor(_ raw: String) -> StageActor? { stage.actors[AgentID(raw)] }
}

func hook(_ event: String, _ extra: String = "", session: String = "s1", cwd: String = "/w/a-sdn-portal") -> String {
    #"{"session_id":"\#(session)","cwd":"\#(cwd)","hook_event_name":"\#(event)"\#(extra.isEmpty ? "" : "," + extra)}"#
}

func tool(_ event: String, _ name: String, _ id: String, _ input: String = "{}", agent: String? = nil) -> String {
    hook(event, #""tool_name":"\#(name)","tool_use_id":"\#(id)","tool_input":\#(input)"# + (agent.map { #","agent_id":"\#($0)","agent_type":"general-purpose""# } ?? ""))
}

@Suite("무대: 연출 지시 실행")
struct StageTests {
    @Test("출근: 문에서 등장해 걸어가 자리에 앉는다")
    func arrival() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        let lead = try! #require(h.actor("lead-1"))
        #expect(lead.position == OfficeLayout().doorPoint)
        #expect(lead.isWalking)
        #expect(!lead.seated)
        h.run(until: 12)
        let seated = try! #require(h.actor("lead-1"))
        #expect(seated.position == h.stage.layout.seat(TeamID("/w/a-sdn-portal#1"), .main).final)
        #expect(seated.seated)
        #expect(seated.facing == .front)
        #expect(h.events.contains(.spawned(AgentID("lead-1"))))
        #expect(h.events.contains { if case .teamOpened(let team) = $0 { team.name == "a-sdn-portal" } else { false } })
    }

    @Test("걷는 시간은 거리 / 속도이고, 걷는 동안 다음 지시를 기다린다")
    func walkTiming() {
        var stage = Stage()
        var engine = OfficeEngine(seed: 1)
        let directives = (try? engine.handle(hookPayload: Data(hook("SessionStart", cwd: "/w/t").utf8), at: Date())) ?? []
        stage.enqueue(directives)
        let lead = AgentID("lead-1")
        // 말풍선은 도착한 뒤에 나옵니다 (walk가 막고 있음)
        #expect(stage.actors[lead]?.bubble == nil)
        var elapsed = 0.0
        while stage.actors[lead]?.isWalking == true, elapsed < 20 {
            stage.update(dt: 0.05)
            elapsed += 0.05
        }
        #expect(stage.actors[lead]?.bubble != nil)
        #expect(stage.actors[lead]?.gesture == .wave)
        // 문(오른쪽 위)에서 왼쪽 위 팀장실까지 칸막이 출입구로 돌아 들어갑니다
        #expect(elapsed > 4 && elapsed < 9)
    }

    @Test("승인 요청은 걷던 중이어도 바로 손을 들고, 목적지까지는 계속 걸어간다 (clearQueue)")
    func clearQueueDuringWalk() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 0.5)
        h.hook(tool("PermissionRequest", "Bash", "p1", #"{"command":"npm test"}"#))
        var lead = h.actor("lead-1")!
        #expect(lead.isWalking)
        #expect(lead.pose == .raisingHand)
        #expect(lead.bubble?.kind == .shout)
        #expect(lead.emote == .exclamation)
        h.run(until: 12)
        lead = h.actor("lead-1")!
        // 연출 엔진이 알고 있는 자리(팀장석)에 도착해 있어야 이후 연출과 어긋나지 않습니다
        #expect(lead.position == h.stage.layout.seat(TeamID("/w/a-sdn-portal#1"), .main).final)
        #expect(lead.pose == .raisingHand)
    }

    @Test("위임과 보고: 팀원이 팀장 옆에 왔다가 자리로 가고, 보고 후 문으로 나가 사라진다")
    func delegationAndReport() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 10)
        h.hook(tool("PreToolUse", "Agent", "a1", #"{"description":"리뷰","subagent_type":"general-purpose"}"#))
        h.hook(hook("SubagentStart", #""agent_id":"g1","agent_type":"general-purpose""#), at: 10.1)
        h.run(until: 26)
        let member = try! #require(h.actor("member-2"))
        #expect(member.position == h.stage.layout.seat(TeamID("/w/a-sdn-portal#1"), Seat(desk: 1)).final)
        #expect(member.seated)

        h.hook(hook("SubagentStop", #""agent_id":"g1","agent_type":"general-purpose""#), at: 28)
        // 팀장은 팀원이 도착할 때까지 하이파이브를 기다립니다
        h.run(until: 28.2)
        #expect(h.actor("lead-1")?.gesture != .highFive)
        // (가끔 탕비 코너에서 물 한 잔 마시고 퇴근합니다)
        h.run(until: 50)
        #expect(h.actor("member-2") == nil)
        #expect(h.events.contains(.despawned(AgentID("member-2"))))
        #expect(h.events.contains(.sound(.memberReport, AgentID("member-2"))))
    }

    @Test("같은 구역에 여럿이 가면 다른 자리에 선다")
    func reservations() {
        var h = StageHarness()
        h.hook(hook("Stop", session: "s1"))
        h.hook(hook("Stop", session: "s2", cwd: "/w/other"))
        h.run(until: 75)
        let a = h.actor("lead-1")!.position
        let b = h.actor("lead-2")!.position
        #expect(a != b)
        #expect(a.distance(to: b) > 20)
    }

    @Test("퇴근: 세션이 끝나면 문으로 걸어가 사라지고, 자리 예약이 풀린다")
    func leaving() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 10)
        h.hook(hook("SessionEnd"))
        h.run(until: 22)
        #expect(h.stage.actors.isEmpty)
        // 다시 출근하면 같은 팀장석에 앉을 수 있습니다
        h.hook(hook("SessionStart", session: "s9"))
        h.run(until: 36)
        #expect(h.actor("lead-2")?.position == h.stage.layout.seat(TeamID("/w/a-sdn-portal#1"), .main).final)
    }

    @Test("말풍선은 표시 시간이 지나면 사라지고, 외침 풍선은 닫을 때까지 남는다")
    func bubbles() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 7.5)
        #expect(h.actor("lead-1")?.bubble != nil)
        h.run(until: 14)
        #expect(h.actor("lead-1")?.bubble == nil)
        h.hook(hook("Notification", #""notification_type":"permission_prompt","message":"x""#))
        h.run(until: 40)
        #expect(h.actor("lead-1")?.bubble?.kind == .shout)
        h.hook(hook("Stop"))
        h.run(until: 41)
        #expect(h.actor("lead-1")?.bubble?.kind != .shout)
    }

    @Test("관찰 시나리오를 끝까지 돌려도 아무도 갇히거나 남지 않는다")
    func observedScenario() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scenarios/m0-observed.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        var h = StageHarness()
        for line in lines {
            let value = try JSONValue.parse(String(line))
            let t = value["t"]?.doubleValue ?? h.now
            h.hook(value["hook"]!.serialized(pretty: false), at: t)
        }
        h.run(until: h.now + 15)
        #expect(h.stage.actors.isEmpty)
    }
}

@Suite("그림 데이터와 SVG")
struct ArtTests {
    @Test("앉으면 앉은 자세. 책상마다 직함 명패(★ 메인, 서브)를 달고, 퇴근하면 책상과 명패를 치운다")
    func nameplatesAndSitting() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(tool("PreToolUse", "Agent", "a1", #"{"subagent_type":"code-reviewer"}"#))
        h.run(until: 20)
        #expect(h.actor("lead-1")?.pose == .sitting)
        let team = TeamID("/w/a-sdn-portal#1")
        #expect(h.stage.nameplates[team]?[.main] == "★ 메인")
        // 책상은 사람마다 하나라 서브 책상에도 직함 명패를 답니다 (에이전트 종류는 쓰지 않음)
        #expect(h.stage.nameplates[team]?[Seat(desk: 1)] == "서브")
        #expect(h.actor("member-2")?.agent.displayName == "서브")
        h.hook(tool("PostToolUse", "Agent", "a1"))
        h.run(until: 45)
        #expect(h.actor("member-2") == nil)
        #expect(h.stage.nameplates[team]?.count == 1)
    }

    @Test("SVG 렌더러는 모든 표정·헤어·액세서리·소품 조합을 그린다")
    func svgCoversArt() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 10)
        let svg = SVGRenderer.render(stage: h.stage)
        #expect(svg.hasPrefix("<svg"))
        #expect(svg.contains("a-sdn-portal"))
        #expect(svg.contains("★ 메인"))
        for expression in [FacialExpression.neutral, .happy, .focus, .think, .surprised, .troubled, .sleepy, .proud, .sad, .eager] {
            #expect(!CharacterArt.eyes(expression).isEmpty)
            #expect(!CharacterArt.mouth(expression).isEmpty)
        }
        for style in 0..<Appearance.hairStyleCount {
            #expect(!CharacterArt.hairBack(style: style).isEmpty && !CharacterArt.hairFront(style: style).isEmpty)
        }
        for accessory in Accessory.allCases { #expect(!CharacterArt.accessory(accessory).isEmpty) }
        #expect(!CharacterArt.heldProp(.book).isEmpty && !CharacterArt.handProp(.cup).isEmpty && !CharacterArt.handProp(.drink).isEmpty)
        for emote in [Emote.exclamation, .question, .bulb, .sweat, .sparkle, .zzz, .note, .hourglass] {
            #expect(!OverlayArt.emote(emote).isEmpty)
        }
        // 탕비 코너·출입문을 그리고, 팀장실·리서치 데스크는 없다 (M5(1))
        #expect(svg.contains("입구") && !svg.contains("팀장실") && !svg.contains("리서치") && svg.contains("탕비 코너"))
    }

    @Test("걸을 때 다리가 번갈아 들리고, 승인 대기 중에는 오른팔이 위로 올라간다")
    func rigPose() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 0.6)
        let walking = RigAnimator.pose(for: h.actor("lead-1")!, time: h.stage.time)
        #expect(walking.leftLegLift != 0 || walking.rightLegLift != 0)
        h.hook(tool("PermissionRequest", "Bash", "p", #"{"command":"ls"}"#))
        h.run(until: 9)
        let raising = RigAnimator.pose(for: h.actor("lead-1")!, time: h.stage.time)
        #expect(raising.rightArm < -140)
    }
}
