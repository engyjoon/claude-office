import Foundation
import OfficeCore
import OfficeServer
import OfficeStage

// office-sim: 앱 없이 연출 엔진을 확인하는 개발용 도구
//
//   office-sim run <scenario.jsonl> [--privacy detailed|summary|hidden] [--seed N] [--tail 초]
//       시나리오의 훅을 시간 순서대로 엔진에 넣고, 0.25초마다 tick을 돌려 지시 타임라인을 출력합니다.
//   office-sim sounds <출력 폴더>
//       모든 효과음을 WAV(44.1kHz, 16비트, 모노)로 저장합니다.
//   office-sim serve [--port N] [--endpoint 파일] [--privacy …] [--roster-only]
//       맥 앱 없이 훅 서버와 엔진만 돌립니다 (헤드리스). 받은 훅의 연출 지시와 직원 목록을 출력합니다.
//   office-sim snapshot <scenario.jsonl> --at 3,12.5 [--out 폴더] [--size 1140x648]
//       시나리오를 엔진과 무대에 흘려서 지정한 시각의 사무실 장면을 SVG로 저장합니다 (맥 없이 그림 확인).
//       --size는 사무실 영역 크기(배율 1)로, 들어가지 않는 행·서브는 앱처럼 숨기고 "+N"을 답니다.
//   office-sim replay <scenario.jsonl> [--endpoint 파일] [--speed 배속]
//       시나리오의 훅을 실행 중인 앱(또는 serve)으로 실제 훅처럼 보냅니다 (curl 사용).
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
          office-sim serve [--port N] [--endpoint 파일] [--privacy …] [--roster-only]
          office-sim snapshot <scenario.jsonl> --at 3,12.5 [--out 폴더] [--size 1140x648]
          office-sim replay <scenario.jsonl> [--endpoint 파일] [--speed 배속]
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
    /// 앱이 데스크톱 세션 정보로 붙이는 방 힌트 ({"ancestors": [...], "rootCwd": ..., "title": ...})
    var hint: SessionHint?

    func event(at date: Date) -> OfficeEvent? {
        guard var event = HookParser.parse(payload, term: term, receivedAt: date) else { return nil }
        event.hint = hint
        return event
    }
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
        var hint: SessionHint?
        if let raw = value["hint"] {
            let ancestors = raw["ancestors"]?.arrayValue?.compactMap { $0.stringValue.map(SessionID.init) } ?? []
            hint = SessionHint(
                hostSession: raw["hostSession"]?.stringValue, ancestors: ancestors,
                rootCwd: raw["rootCwd"]?.stringValue, title: raw["title"]?.stringValue)
        }
        steps.append(ScenarioStep(
            time: time, term: value["term"]?.stringValue ?? value["term_program"]?.stringValue, payload: payload, hint: hint))
    }
    return steps.sorted { $0.time < $1.time }
}

func run(_ arguments: [String]) throws {
    guard let path = arguments.first, !path.hasPrefix("--") else { usage() }
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
            if let event = step.event(at: epoch.addingTimeInterval(step.time)) {
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

// MARK: - serve

/// 버퍼 없이 바로 출력합니다 (파일로 돌려도 실시간으로 보이도록)
func emit(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

/// 엔진은 값 타입이라 직렬 큐 하나에서만 만집니다.
final class EngineBox: @unchecked Sendable {
    let queue = DispatchQueue(label: "office-sim.engine")
    var engine: OfficeEngine
    var lastRoster = Roster.empty
    let rosterOnly: Bool
    let privacy: PrivacyLevel
    let started = Date()

    init(privacy: PrivacyLevel, rosterOnly: Bool) {
        self.privacy = privacy
        self.rosterOnly = rosterOnly
        engine = OfficeEngine(privacy: privacy)
    }

    func stamp(_ date: Date) -> String {
        String(format: "%8.2fs", date.timeIntervalSince(started))
    }

    func receive(_ delivery: HookDelivery) {
        let name = (try? JSONValue.parse(delivery.body))?["hook_event_name"]?.stringValue ?? "?"
        do {
            let directives = try engine.handle(hookPayload: delivery.body, term: delivery.term, at: delivery.receivedAt)
            emit("\(stamp(delivery.receivedAt))  ── 훅 \(name) (\(delivery.term ?? "터미널 모름"))")
            show(directives, at: delivery.receivedAt)
        } catch {
            emit("\(stamp(delivery.receivedAt))  ── 훅 \(name): JSON을 읽을 수 없습니다 (\(error))")
        }
    }

    func tick() {
        let now = Date()
        show(engine.tick(at: now), at: now)
    }

    func show(_ directives: [Directive], at date: Date) {
        if !rosterOnly {
            for directive in directives { emit("\(stamp(date))     \(directive)") }
        }
        let roster = Roster.make(from: engine.state, privacy: privacy)
        if roster != lastRoster {
            lastRoster = roster
            emit("\(stamp(date))  ☰ \(describe(roster))")
        }
    }

    func describe(_ roster: Roster) -> String {
        if roster.teams.isEmpty { return "사무실이 비어 있어요" }
        let teams = roster.teams.map { team in
            let rows = team.rows.map { row in "\(row.name)(\(row.status.label)\(row.detail.map { " · \($0)" } ?? ""))" }
            return "\(team.name): \(rows.joined(separator: ", "))"
        }
        return "[\(roster.mood.rawValue)] " + teams.joined(separator: " | ")
    }
}

func serve(_ arguments: [String]) throws -> Never {
    let privacy = option("--privacy", in: arguments).flatMap(PrivacyLevel.init(rawValue:)) ?? .detailed
    let port = option("--port", in: arguments).flatMap(UInt16.init) ?? HookServer.defaultPort
    let endpoint = option("--endpoint", in: arguments).map { URL(fileURLWithPath: $0) } ?? EndpointFile.defaultURL()
    let box = EngineBox(privacy: privacy, rosterOnly: arguments.contains("--roster-only"))

    let token = HookRequestPolicy.makeToken()
    let server = HookServer(token: token) { delivery in
        box.queue.async { box.receive(delivery) }
    }
    let bound = try server.start(preferredPort: port)
    try EndpointFile.write(port: bound, token: token, to: endpoint)
    emit("훅 서버: 127.0.0.1:\(bound)  엔드포인트: \(endpoint.path)  (Ctrl+C로 종료)")

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let shutdown: @Sendable () -> Void = {
        server.stop()
        EndpointFile.remove(at: endpoint)
        emit("\n종료했습니다. 엔드포인트 파일을 지웠습니다.")
        exit(0)
    }
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: box.queue)
    interrupt.setEventHandler(handler: shutdown)
    interrupt.resume()
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: box.queue)
    terminate.setEventHandler(handler: shutdown)
    terminate.resume()

    let timer = DispatchSource.makeTimerSource(queue: box.queue)
    timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
    timer.setEventHandler { box.tick() }
    timer.resume()
    dispatchMain()
}

// MARK: - snapshot

func snapshot(_ arguments: [String]) throws {
    guard let path = arguments.first, !path.hasPrefix("--") else { usage() }
    let times = (option("--at", in: arguments) ?? "5").split(separator: ",").compactMap { Double($0) }.sorted()
    let folder = URL(fileURLWithPath: option("--out", in: arguments) ?? "build/snapshots")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let steps = try loadScenario(path)
    var engine = OfficeEngine(seed: option("--seed", in: arguments).flatMap(UInt64.init) ?? 1)
    // 사무실 창 크기 (기본: 창 1400×700에서 직원 현황 패널을 뺀 영역). 배율 1로 그립니다.
    let size = (option("--size", in: arguments) ?? "").split(separator: "x").compactMap { Double($0) }
    var floor = OfficeFloor(
        width: size.count == 2 ? size[0] : OfficeLayout.defaultWidth, height: size.count == 2 ? size[1] : OfficeLayout.defaultHeight)
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let frame = 1.0 / 30
    var now = 0.0
    var nextTick = 0.25
    var pending = steps[...]
    let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    for target in times {
        while now < target {
            while let step = pending.first, step.time <= now {
                pending = pending.dropFirst()
                if let event = step.event(at: epoch.addingTimeInterval(step.time)) {
                    let directives = engine.handle(event)
                    floor.apply(directives, engine: engine)
                }
            }
            let dt = min(frame, target - now)
            now += dt
            floor.update(dt: dt)
            if now >= nextTick {
                let directives = engine.tick(at: epoch.addingTimeInterval(now))
                floor.apply(directives, engine: engine)
                nextTick += 0.25
            }
            _ = floor.drainEvents()
        }
        let stage = floor.stage
        let file = folder.appendingPathComponent(String(format: "%@-%06.2fs.svg", base, target))
        try SVGRenderer.render(stage: stage).write(to: file, atomically: true, encoding: .utf8)
        let summary = stage.sortedActors.map { actor in
            "\(actor.agent.displayName)@\(actor.position)\(actor.isWalking ? "→" : "")\(actor.seated ? "(앉음)" : "") \(actor.pose.rawValue)"
        }.joined(separator: ", ")
        print(String(format: "%7.2fs  %@", target, file.path))
        print("          \(summary.isEmpty ? "(아무도 없음)" : summary)")
        if floor.plan.hiddenCount > 0 { print("          화면에 다 못 보여 준 \(floor.plan.hiddenCount)명") }
    }
}

// MARK: - replay

func replay(_ arguments: [String]) throws {
    guard let path = arguments.first, !path.hasPrefix("--") else { usage() }
    let endpointURL = option("--endpoint", in: arguments).map { URL(fileURLWithPath: $0) } ?? EndpointFile.defaultURL()
    let speed = max(option("--speed", in: arguments).flatMap(Double.init) ?? 1, 0.01)
    let endpoint: (port: UInt16, token: String)
    do {
        endpoint = try EndpointFile.read(from: endpointURL)
    } catch {
        throw Failure(description: "\(endpointURL.path)을(를) 읽을 수 없습니다. Claude Office 앱이나 office-sim serve가 실행 중인지 확인해 주세요.")
    }
    let steps = try loadScenario(path)
    var previous = steps.first?.time ?? 0
    var sent = 0
    for step in steps {
        let wait = (step.time - previous) / speed
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        previous = step.time
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "curl", "-s", "-m", "2", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
            "-H", "Content-Type: application/json", "-H", "X-Office-Token: \(endpoint.token)",
            "-H", "X-Office-Term: \(step.term ?? "unknown")", "--data-binary", "@-",
            "http://127.0.0.1:\(endpoint.port)\(HookRequestPolicy.path)",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(step.payload.serialized(pretty: false).utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let code = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let name = step.payload["hook_event_name"]?.stringValue ?? "?"
        print(String(format: "%8.2fs  %@ %@", step.time, code, name))
        if code == "202" { sent += 1 }
    }
    print("\n\(steps.count)개 중 \(sent)개를 보냈습니다 (\(speed)배속).")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "run": try run(Array(arguments.dropFirst()))
    case "sounds": try sounds(Array(arguments.dropFirst()))
    case "serve": try serve(Array(arguments.dropFirst()))
    case "replay": try replay(Array(arguments.dropFirst()))
    case "snapshot": try snapshot(Array(arguments.dropFirst()))
    default: usage()
    }
} catch {
    FileHandle.standardError.write(Data("오류: \(error)\n".utf8))
    exit(1)
}
