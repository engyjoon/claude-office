import Foundation
import OfficeCore

// office-sim: 앱 없이 연출 엔진을 확인하는 개발용 도구
//
//   office-sim run <scenario.jsonl> [--privacy detailed|summary|hidden] [--seed N] [--tail 초]
//       시나리오의 훅을 시간 순서대로 엔진에 넣고, 0.25초마다 tick을 돌려 지시 타임라인을 출력합니다.
//   office-sim sounds <출력 폴더>
//       모든 효과음을 WAV(44.1kHz, 16비트, 모노)로 저장합니다.
//
// 시나리오 한 줄 형식 (JSON Lines, '#'로 시작하는 줄은 주석):
//   {"t": 12.5, "term": "iTerm.app", "hook": { ...훅 페이로드... }}
// 수집 도구의 캡처 형식({"captured_at", "term_program", "payload"})도 읽습니다. 이때 t가 없으면 앞 줄 + 1초입니다.

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func usage() -> Never {
    print(
        """
        사용법:
          office-sim run <scenario.jsonl> [--privacy detailed|summary|hidden] [--seed N] [--tail 초]
          office-sim sounds <출력 폴더>
        """)
    exit(2)
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

struct ScenarioStep {
    var time: Double
    var term: String?
    var payload: JSONValue
}

func loadScenario(_ path: String) throws -> [ScenarioStep] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var steps: [ScenarioStep] = []
    var lastTime = -1.0
    for (number, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let value: JSONValue
        do {
            value = try JSONValue.parse(line)
        } catch {
            throw Failure(description: "\(path):\(number + 1): \(error)")
        }
        guard let payload = value["hook"] ?? value["payload"] else {
            throw Failure(description: "\(path):\(number + 1): \"hook\" 또는 \"payload\"가 필요합니다")
        }
        let time = value["t"]?.doubleValue ?? (lastTime + 1)
        lastTime = time
        steps.append(ScenarioStep(time: time, term: value["term"]?.stringValue ?? value["term_program"]?.stringValue, payload: payload))
    }
    return steps.sorted { $0.time < $1.time }
}

func run(_ arguments: [String]) throws {
    guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else { usage() }
    let privacy = option("--privacy", in: arguments).flatMap(PrivacyLevel.init(rawValue:)) ?? .detailed
    let seed = option("--seed", in: arguments).flatMap(UInt64.init) ?? 1
    let tail = option("--tail", in: arguments).flatMap(Double.init) ?? 3

    let steps = try loadScenario(path)
    var engine = OfficeEngine(privacy: privacy, seed: seed)
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let end = (steps.last?.time ?? 0) + tail
    var pending = steps[...]
    var now = 0.0
    var printed = 0

    func emit(_ directives: [Directive], at time: Double, label: String? = nil) {
        if let label { print(String(format: "%8.2fs  ── %@", time, label)) }
        for directive in directives {
            print(String(format: "%8.2fs     %@", time, directive.description))
            printed += 1
        }
    }

    while now <= end {
        while let step = pending.first, step.time <= now {
            pending = pending.dropFirst()
            let name = step.payload["hook_event_name"]?.stringValue ?? "?"
            let tool = step.payload["tool_name"]?.stringValue.map { " \($0)" } ?? ""
            let agent = step.payload["agent_id"]?.stringValue.map { " (서브에이전트 \($0))" } ?? ""
            if let event = HookParser.parse(step.payload, term: step.term, receivedAt: epoch.addingTimeInterval(step.time)) {
                emit(engine.handle(event), at: step.time, label: "훅 \(name)\(tool)\(agent)")
            } else {
                print(String(format: "%8.2fs  ── 훅 %@%@ (무시)", step.time, name, tool))
            }
        }
        emit(engine.tick(at: epoch.addingTimeInterval(now)), at: now)
        now += 0.25
    }
    print("\n지시 \(printed)개, 남은 직원 \(engine.state.agents.count)명, 팀 \(engine.state.teams.count)개 (표시 수준: \(privacy.rawValue))")
}

func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let byteCount = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 2))
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(byteCount))
    for sample in samples {
        append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
    }
    try data.write(to: url)
}

func sounds(_ arguments: [String]) throws {
    guard let folder = arguments.first else { usage() }
    let directory = URL(fileURLWithPath: folder)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let renderer = SoundRenderer()
    var rng = SeededRandom(seed: 9)
    var cues: [(String, SoundCue)] = [
        ("approval-knock", .knock), ("input-waiting", .inputWaiting), ("turn-complete", .turnComplete),
        ("member-report", .memberReport), ("door", .door), ("error", .error), ("chatter", .chatter),
        ("footsteps", .footsteps), ("typing", .typing),
    ]
    for voice in 0..<SoundLibrary.voicePitches.count {
        cues.append(("bubble-voice\(voice)", .bubble(voice: voice, syllables: 3)))
    }
    for (name, cue) in cues {
        let recipe = SoundLibrary.recipe(for: cue, using: &rng)
        let samples = renderer.render(recipe)
        let url = directory.appendingPathComponent("\(name).wav")
        try writeWAV(samples, sampleRate: Int(renderer.sampleRate), to: url)
        let peak = samples.map(abs).max() ?? 0
        print(String(format: "%-20@ %-24@ %.2f초  최대 %.2f", name, cue.description, recipe.duration, peak))
    }
    print("\n\(cues.count)개 파일을 \(directory.path)에 저장했습니다.")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "run": try run(Array(arguments.dropFirst()))
    case "sounds": try sounds(Array(arguments.dropFirst()))
    default: usage()
    }
} catch {
    FileHandle.standardError.write(Data("오류: \(error)\n".utf8))
    exit(1)
}
