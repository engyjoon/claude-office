import Foundation
import Testing

@testable import OfficeCore

/// 테스트 공용 도우미
enum Fixture {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    /// 캡처 형식({captured_at, term_program, payload})의 픽스처에서 payload만 꺼냅니다.
    static func payload(_ name: String, folder: String = "synthetic") throws -> JSONValue {
        let url = directory.appendingPathComponent(folder).appendingPathComponent("\(name).json")
        let record = try JSONValue.parse(Data(contentsOf: url))
        return try #require(record["payload"])
    }

    static func files(in folder: String) -> [URL] {
        let url = directory.appendingPathComponent(folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { url.appendingPathComponent($0) }
    }

    static func event(_ name: String, at seconds: Double = 0) throws -> OfficeEvent {
        let payload = try payload(name)
        return try #require(HookParser.parse(payload, term: "iTerm.app", receivedAt: epoch.addingTimeInterval(seconds)))
    }
}

/// 훅 페이로드를 코드로 짧게 만드는 도우미
struct Hook {
    var session = "s1"
    var cwd = "/Users/demo/work/a-sdn-portal"

    func make(_ name: String, _ extra: JSONObject = JSONObject(), agent: (id: String, type: String)? = nil) -> JSONValue {
        var object = JSONObject()
        object["session_id"] = .string(session)
        object["cwd"] = .string(cwd)
        object["hook_event_name"] = .string(name)
        for entry in extra.entries { object[entry.key] = entry.value }
        if let agent {
            object["agent_id"] = .string(agent.id)
            object["agent_type"] = .string(agent.type)
        }
        return .object(object)
    }

    func tool(_ hook: String, _ tool: String, id: String?, input: JSONValue, agent: (id: String, type: String)? = nil, extra: [(String, JSONValue)] = []) -> JSONValue {
        var object = JSONObject([("tool_name", .string(tool)), ("tool_input", input)])
        if let id { object["tool_use_id"] = .string(id) }
        for (key, value) in extra { object[key] = value }
        return make(hook, object, agent: agent)
    }
}

/// 엔진에 시간 순서대로 훅을 넣고 지시를 모으는 하네스
struct EngineHarness {
    var engine: OfficeEngine
    var now: Double = 0
    var nextTick: Double = 0.25
    var log: [(time: Double, directive: Directive)] = []

    init(privacy: PrivacyLevel = .detailed, config: ChoreographyConfig = .init(), seed: UInt64 = 7) {
        engine = OfficeEngine(privacy: privacy, config: config, seed: seed)
    }

    var date: Date { Fixture.epoch.addingTimeInterval(now) }

    @discardableResult
    mutating func send(_ payload: JSONValue, at seconds: Double? = nil) -> [Directive] {
        if let seconds { advance(to: seconds) }
        guard let event = HookParser.parse(payload, term: "iTerm.app", receivedAt: date) else { return [] }
        let directives = engine.handle(event)
        log += directives.map { (now, $0) }
        return directives
    }

        /// 0.25초 간격의 고정 시점마다 tick을 실행합니다 (앱의 화면 주기와 같은 방식).
    @discardableResult
    mutating func advance(to seconds: Double) -> [Directive] {
        var produced: [Directive] = []
        while nextTick <= seconds {
            now = nextTick
            nextTick += 0.25
            let directives = engine.tick(at: date)
            produced += directives
            log += directives.map { (now, $0) }
        }
        now = max(now, seconds)
        return produced
    }

    func actions(of agent: AgentID) -> [Directive.Action] {
        log.filter { $0.directive.agent == agent }.map(\.directive.action)
    }

    var all: [Directive] { log.map(\.directive) }
}

extension Array where Element == Directive {
    var sounds: [SoundCue] {
        compactMap { if case .sound(let cue) = $0.action { cue } else { nil } }
    }

    var bubbles: [Bubble] {
        compactMap { if case .say(let bubble) = $0.action { bubble } else { nil } }
    }
}

extension Array where Element == Directive.Action {
    var walks: [Spot] {
        compactMap { if case .walk(let spot) = $0 { spot } else { nil } }
    }

    var bubbles: [Bubble] {
        compactMap { if case .say(let bubble) = $0 { bubble } else { nil } }
    }

    var statusTexts: [String?] {
        compactMap { if case .status(let pill) = $0 { pill?.text } else { nil } }
    }
}
