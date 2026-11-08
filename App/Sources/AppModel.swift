import AppKit
import Foundation
import Observation
import OfficeCore
import OfficeServer
import OfficeStage

/// 앱 전체 상태. 훅 서버 → 엔진 → 로스터를 잇고, 화면은 이 값만 봅니다.
///
/// 모든 상태 변경은 메인 액터에서 일어납니다. 훅 서버는 백그라운드 큐에서 훅을 넘겨주므로
/// `DispatchQueue.main`으로 옮긴 뒤 처리합니다 (도착 순서 유지).
@MainActor
@Observable
final class AppModel {
    enum ServerState: Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    struct LogEntry: Identifiable, Equatable {
        enum Kind: Equatable {
            case hook, directive, system
        }

        let id = UUID()
        let date: Date
        let kind: Kind
        let text: String
    }

    private(set) var roster: Roster = .empty
    private(set) var serverState: ServerState = .stopped
    private(set) var hookStatus: HookInstaller.Status = .notInstalled
    private(set) var privacy: PrivacyLevel = .detailed
    private(set) var log: [LogEntry] = []
    private(set) var installMessage: String?
    private(set) var isInstalling = false
    private(set) var receivedHooks = 0
    /// 사무실 창에서 클릭해 고른 직원 (신원 카드에 보여줍니다)
    private(set) var selectedAgent: AgentID?
    /// 효과음 설정 (설계서 §11.3). 설정 창과 메뉴바에서 바꿉니다.
    private(set) var soundSettings: SoundSettings

    @ObservationIgnored private var engine: OfficeEngine
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    let installer = HookInstaller()
    let endpointURL = EndpointFile.defaultURL()
    /// 데스크톱 앱 세션 정보 (방·직함 힌트, 설계서 §4.4)
    let desktopSessions = DesktopSessionDirectory()
    /// 무대 상태 (M3). 사무실 창이 닫혀 있어도 계속 흘러가야 하므로 씬이 아니라 모델이 갱신합니다.
    let stageStore = StageStore()
    let officeScene: OfficeScene
    @ObservationIgnored private let soundPlayer: SoundPlayer
    @ObservationIgnored private var lastFrame = Date()
    @ObservationIgnored private var tickAccumulator = 0.0

    private static let privacyKey = "privacy"
    private static let maxLogEntries = 600

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.privacyKey).flatMap(PrivacyLevel.init(rawValue:)) ?? .detailed
        privacy = saved
        engine = OfficeEngine(privacy: saved)
        let sound = SoundSettings(defaults: .standard)
        soundSettings = sound
        soundPlayer = SoundPlayer(settings: sound)
        stageStore.privacy = saved
        officeScene = OfficeScene(store: stageStore)
        officeScene.onSelect = { [weak self] id in self?.select(id) }
        refreshHookStatus()
        startServer()
        startTicking()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    // MARK: - 서버

    func startServer() {
        server?.stop()
        let token = HookRequestPolicy.makeToken()
        let directory = desktopSessions
        let server = HookServer(token: token) { [weak self] delivery in
            // 정보 파일은 전달 큐(백그라운드)에서 읽고, 메인 액터에는 결과만 넘깁니다
            let hint = delivery.hostSession.flatMap { directory.hint(forHostSession: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(delivery, hint: hint) }
            }
        }
        do {
            let port = try server.start()
            try EndpointFile.write(port: port, token: token, to: endpointURL)
            self.server = server
            serverState = .running(port: port)
            append(.system, "훅 서버를 시작했어요 (127.0.0.1:\(port))")
        } catch {
            server.stop()
            serverState = .failed("\(error)")
            append(.system, "훅 서버를 시작하지 못했어요: \(error)")
        }
    }

    func shutdown() {
        timer?.invalidate()
        server?.stop()
        EndpointFile.remove(at: endpointURL)
    }

    /// 30fps로 무대를 흘리고, 0.25초마다 연출 엔진의 tick을 돌립니다.
    private func startTicking() {
        lastFrame = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func frame() {
        let now = Date()
        let dt = min(max(now.timeIntervalSince(lastFrame), 0), 0.1)
        lastFrame = now
        stageStore.stage.update(dt: dt)
        tickAccumulator += dt
        if tickAccumulator >= 0.25 {
            tickAccumulator = 0
            record(engine.tick(at: now))
        }
        playSounds(stageStore.stage.drainEvents())
    }

    /// 무대에서 나온 효과음을 재생기에 넘깁니다. 알림성 소리는 창이 안 보여도, 장식성 소리는 보일 때만 울립니다.
    private func playSounds(_ events: [StageEvent]) {
        var context: SoundContext?
        for event in events {
            guard case .sound(let cue, _) = event, soundSettings.isEnabled(cue.group) else { continue }
            if context == nil {
                // 집중 모드 감지는 알림(M5)과 함께 붙입니다
                context = SoundContext(officeVisible: officeScene.isVisibleOnScreen, focusModeActive: false)
            }
            soundPlayer.play(cue, context: context!)
        }
    }

    private func receive(_ delivery: HookDelivery, hint: SessionHint?) {
        receivedHooks += 1
        do {
            let directives = try engine.handle(hookPayload: delivery.body, term: delivery.term, hint: hint, at: delivery.receivedAt)
            append(.hook, Self.summary(of: delivery, hint: hint))
            record(directives)
        } catch {
            append(.system, "읽을 수 없는 훅을 받았어요: \(error)")
        }
        roster = Roster.make(from: engine.state, privacy: privacy)
        // 고른 직원이 퇴근하면 카드를 닫습니다
        if let selectedAgent, roster.row(for: selectedAgent) == nil { select(nil) }
    }

    func select(_ id: AgentID?) {
        selectedAgent = id
        officeScene.selectedAgent = id
    }

    /// 연출 지시를 무대에 넘기고, 로그에도 남깁니다.
    private func record(_ directives: [Directive]) {
        guard !directives.isEmpty else { return }
        stageStore.stage.enqueue(directives)
        for directive in directives {
            append(.directive, directive.description)
        }
    }

    // MARK: - 설정

    func setSoundSettings(_ settings: SoundSettings) {
        soundSettings = settings
        settings.save(to: .standard)
        soundPlayer.update(settings)
    }

    func previewSound(_ group: SoundGroup) {
        soundPlayer.preview(group)
    }

    func setPrivacy(_ level: PrivacyLevel) {
        privacy = level
        stageStore.privacy = level
        engine.privacy = level
        UserDefaults.standard.set(level.rawValue, forKey: Self.privacyKey)
        roster = Roster.make(from: engine.state, privacy: level)
    }

    func refreshHookStatus() {
        hookStatus = installer.status()
    }

    func installHooks() {
        guard !isInstalling else { return }
        isInstalling = true
        installMessage = "Claude Code 버전을 확인하는 중이에요…"
        let installer = self.installer
        Task.detached(priority: .userInitiated) {
            let version = ClaudeVersionDetector.detect()
            let result = Result { try installer.install(version: version) }
            await MainActor.run { self.finishInstall(result) }
        }
    }

    private func finishInstall(_ result: Result<HookInstaller.Report, Error>) {
        isInstalling = false
        switch result {
        case .success(let report):
            var message = "훅을 설치했어요. 이벤트 \(report.events.count)개"
            message += report.version.map { ", Claude Code \($0)" } ?? ", Claude Code 버전을 확인하지 못해 기본 이벤트만 등록"
            if let backup = report.backup { message += "\n기존 설정 백업: \(backup.lastPathComponent)" }
            message += "\n이미 실행 중인 Claude Code 세션은 다시 시작해야 적용돼요."
            installMessage = message
            append(.system, "훅 설치: \(report.events.joined(separator: ", "))")
        case .failure(let error):
            installMessage = "설치하지 못했어요: \(error)"
            append(.system, "훅 설치 실패: \(error)")
        }
        refreshHookStatus()
    }

    func uninstallHooks() {
        do {
            let removed = try installer.uninstall()
            installMessage = "훅 \(removed)개를 제거했어요. 다른 훅과 설정은 그대로예요."
            append(.system, "훅 제거: \(removed)개")
        } catch {
            installMessage = "제거하지 못했어요: \(error)"
        }
        refreshHookStatus()
    }

    /// 설치된 훅 스크립트를 실제로 실행해서, 스크립트 → 엔드포인트 → 서버 경로를 확인합니다.
    func sendTestHook() {
        let script = installer.scriptURL
        let before = receivedHooks
        let session = "claude-office-test-\(Int(Date().timeIntervalSince1970))"
        let payloads = [
            #"{"session_id":"\#(session)","cwd":"/Claude Office 연결 확인","hook_event_name":"SessionStart","source":"startup"}"#,
            #"{"session_id":"\#(session)","cwd":"/Claude Office 연결 확인","hook_event_name":"SessionEnd","reason":"test"}"#,
        ]
        installMessage = "테스트 훅을 보내는 중이에요…"
        Task.detached(priority: .userInitiated) {
            for (index, payload) in payloads.enumerated() {
                if index > 0 { try? await Task.sleep(nanoseconds: 2_500_000_000) }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [script.path]
                let input = Pipe()
                process.standardInput = input
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                do {
                    try process.run()
                    input.fileHandleForWriting.write(Data(payload.utf8))
                    try input.fileHandleForWriting.close()
                    process.waitUntilExit()
                } catch {
                    await MainActor.run { self.installMessage = "훅 스크립트를 실행하지 못했어요: \(error)" }
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                let arrived = self.receivedHooks - before
                self.installMessage = arrived >= 2
                    ? "연결 확인 완료! 훅 스크립트에서 보낸 테스트 이벤트 \(arrived)개가 도착했어요."
                    : "테스트 이벤트가 도착하지 않았어요 (\(arrived)/2). 훅을 다시 설치해 보세요."
            }
        }
    }

    // MARK: - 로그

    func clearLog() {
        log.removeAll()
    }

    private func append(_ kind: LogEntry.Kind, _ text: String) {
        log.append(LogEntry(date: Date(), kind: kind, text: text))
        if log.count > Self.maxLogEntries {
            log.removeFirst(log.count - Self.maxLogEntries)
        }
    }

    private static func summary(of delivery: HookDelivery, hint: SessionHint?) -> String {
        guard let payload = try? JSONValue.parse(delivery.body) else { return "훅" }
        var parts = [payload["hook_event_name"]?.stringValue ?? "?"]
        if let tool = payload["tool_name"]?.stringValue { parts.append(tool) }
        if let type = payload["agent_type"]?.stringValue, !type.isEmpty { parts.append("[\(type)]") }
        if let cwd = payload["cwd"]?.stringValue { parts.append("· \((cwd as NSString).lastPathComponent)") }
        if let term = delivery.term { parts.append("· \(term)") }
        if let hint {
            parts.append(hint.ancestors.isEmpty ? "· 데스크톱 메인" : "· 데스크톱 하위(\(hint.ancestors.count)단계)")
        } else if delivery.hostSession != nil {
            parts.append("· 데스크톱 정보 없음")
        }
        return parts.joined(separator: " ")
    }
}
