import AppKit
import Foundation
import Observation
import OfficeCore
import UserNotifications
import OfficeServer
import OfficeStage
import SwiftUI

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
    /// 마지막으로 훅을 받은 때 (설정 → 연동 "마지막 이벤트", M5(8))
    private(set) var lastHookAt: Date?
    /// 훅 스크립트 파일 상태 (있는지, 실행 가능한지, 앱과 같은 버전인지)
    private(set) var hookScript: HookScriptState = .missing
    /// 테스트 이벤트를 보내는 중 (설정 → 연동)
    private(set) var isSendingTest = false
    /// 동작 줄이기 설정과 macOS 손쉬운 사용 값 (설계서 §10, M5(8))
    private(set) var motionSettings: MotionSettings
    private(set) var systemReduceMotion = false
    /// 사무실 조명을 켜는 기준과 지금 밤인지 (M6(6), 설정 → 일반)
    private(set) var lightingMode: LightingMode
    private(set) var isNight = false
    /// 사무실 창에서 클릭해 고른 직원 (신원 카드에 보여줍니다)
    private(set) var selectedAgent: AgentID?
    /// 효과음 설정 (설계서 §11.3). 설정 창과 메뉴바에서 바꿉니다.
    private(set) var soundSettings: SoundSettings
    /// 사무실 창에서 고른 디렉토리 (패널 위 디렉토리 드롭다운, 하나만). 처음엔 모두.
    private(set) var selection: FloorSelection
    /// 고른 디렉토리의 사람 중 사무실 화면에 다 못 보여 준 수
    private(set) var hiddenOnScreen = 0
    /// Claude 데스크톱 앱에 열려 있는 디렉토리 (몇 초마다 새로 읽음)
    private(set) var directories: [DesktopFolder] = []
    /// 사무실 아래 실시간 현황 줄 (고른 사람의 흐름, 아니면 고른 디렉토리의 최근 일)
    private(set) var statusLine: StatusLine = .empty
    /// 고른 사람의 최근 일 (인스펙터 타임라인, M5(7)). 현황 줄과 같은 때 다시 만듭니다.
    private(set) var inspectorTimeline: AgentTimeline = .empty
    /// 알림 설정 (설계서 §10 알림, M5(3)). 승인 대기 켬, 응답 완료 끔이 기본.
    private(set) var notificationSettings: NotificationSettings
    /// macOS 알림 권한 상태
    private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    /// 집중 모드 상태를 읽을 수 있는지
    private(set) var focusAccess: FocusDetector.Access = .notDetermined
    /// 미니 사무실 (M5(4)): 지금 보여 주는 행과 그 까닭, 사용자가 고정한 행, 설정
    private(set) var miniFocus: MiniFocus = .empty
    /// 미니를 눌러 사무실 창을 여는 중 (창이 뜨기 전에 미니가 다시 나타나지 않게)
    @ObservationIgnored private var miniHiddenUntil = Date.distantPast
    private(set) var miniSettings: MiniOfficeSettings

    @ObservationIgnored private var engine: OfficeEngine
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var directoryTimer: Timer?
    @ObservationIgnored private var loadingDirectories = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var motionObserver: NSObjectProtocol?
    let installer = HookInstaller()
    /// 훅 스크립트가 읽는 엔드포인트 파일. 환경 변수 `CLAUDE_OFFICE_ENDPOINT`로 바꿀 수 있습니다 (훅 스크립트와 같은 이름).
    /// 성능 측정(scripts/perf-launch.sh isolated)은 다른 파일을 써서 실제 세션의 훅이 섞이지 않게 합니다 (M6(1)).
    let endpointURL = ProcessInfo.processInfo.environment["CLAUDE_OFFICE_ENDPOINT"].map { URL(fileURLWithPath: $0) }
        ?? EndpointFile.defaultURL()
    /// 데스크톱 앱 세션 정보 (방·직함 힌트, 설계서 §4.4)
    let desktopSessions = DesktopSessionDirectory()
    /// 무대 상태 (M3). 사무실 창이 닫혀 있어도 계속 흘러가야 하므로 씬이 아니라 모델이 갱신합니다.
    let stageStore = StageStore()
    let officeScene: OfficeScene
    /// 미니 사무실 무대 (한 행 띠, 배율 1). 사무실 창과 같은 연출 지시를 받고, 보여 줄 행만 다릅니다.
    let miniStore = StageStore()
    let miniScene: OfficeScene
    @ObservationIgnored private var miniPanel: MiniOfficePanelController?
    /// 사무실 창 열기 (SwiftUI 장면의 openWindow. 메뉴바 아이콘이 나타날 때 등록)
    @ObservationIgnored private var openOfficeWindowAction: (() -> Void)?
    @ObservationIgnored private let soundPlayer: SoundPlayer
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var lastFrame = Date()
    @ObservationIgnored private var tickAccumulator = 0.0
    /// 사무실 창·미니가 화면에 보이는지 (M6(1)): 안 보이면 SwiftUI 시계 글자도 멈춥니다
    private(set) var officeVisible = false
    private(set) var miniVisible = false
    /// 모델 타이머 간격 (보이는 장면에 맞춰 바뀜, M6(1))
    @ObservationIgnored private var tickInterval = 1.0 / 30
    /// 연출 지시를 받은 뒤 이때까지는 30fps (등장·퇴장 페이드 등)
    @ObservationIgnored private var settleUntil = Date.distantPast
    /// 장면마다 마지막으로 빠른 움직임이 있었거나 연출 지시를 받은 때 (오래 조용하면 잠잠함 3fps)
    @ObservationIgnored private var officeBusyAt = Date()
    @ObservationIgnored private var miniBusyAt = Date()
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []

    private static let selectAllKey = "office.selection.all"
    private static let selectedFoldersKey = "office.selection.folders"
    /// 디렉토리 목록을 새로 읽는 간격
    private static let directoryRefreshInterval: TimeInterval = 5
    private static let maxLogEntries = 600

    init() {
        // 바뀐 설정 키의 값을 먼저 옮겨 둡니다 (M5(8))
        SettingsMigration.migrate(UserDefaults.standard)
        let saved = PrivacyLevel(store: UserDefaults.standard)
        motionSettings = MotionSettings(store: UserDefaults.standard)
        lightingMode = LightingMode(store: UserDefaults.standard)
        privacy = saved
        engine = OfficeEngine(privacy: saved)
        let sound = SoundSettings(defaults: .standard)
        soundSettings = sound
        soundPlayer = SoundPlayer(settings: sound)
        stageStore.privacy = saved
        let notify = NotificationSettings(defaults: .standard)
        notificationSettings = notify
        engine.notificationSettings = notify
        // 고른 디렉토리는 기억해 둡니다 (앱을 다시 켜도 이어짐)
        let defaults = UserDefaults.standard
        let all = defaults.object(forKey: Self.selectAllKey) as? Bool ?? true
        // 디렉토리는 하나만 고릅니다 (예전에 여럿 골라 두었으면 첫 번째만)
        let savedFolder = (defaults.stringArray(forKey: Self.selectedFoldersKey) ?? []).sorted().first
        let selection = savedFolder.map { all ? FloorSelection.everyone : FloorSelection(all: false, folders: [$0]) }
            ?? .everyone
        self.selection = selection
        stageStore.floor = OfficeFloor(selection: selection)
        officeScene = OfficeScene(store: stageStore)
        let mini = MiniOfficeSettings(defaults: defaults)
        miniSettings = mini
        miniStore.privacy = saved
        miniStore.floor = OfficeFloor(
            selection: .nobody, width: MiniOffice.visibleMapWidth(), height: OfficeLayout.minHeight,
            band: true)
        miniScene = OfficeScene(store: miniStore, framing: .band(top: MiniOffice.top))
        officeScene.onSelect = { [weak self] id in self?.select(id) }
        officeScene.onActivate = { [weak self] id in self?.focusAgent(id) }
        officeScene.hoverHelp = { [weak self] id in self?.hoverHelp(for: id, mini: false) }
        officeScene.onViewportChange = { [weak self] size in self?.setViewport(size) }
        miniScene.onSelect = { [weak self] id in self?.openOfficeFromMini(id) }
        miniScene.onActivate = { [weak self] id in self?.focusFromMini(id) }
        miniScene.hoverHelp = { [weak self] id in self?.hoverHelp(for: id, mini: true) }
        miniScene.onViewportChange = { [weak self] size in self?.setMiniViewport(size) }
        notifier.onAuthorizationChange = { [weak self] status in self?.notificationAuthorization = status }
        notifier.onOpen = { [weak self] target in self?.open(target) }
        focusAccess = FocusDetector.access
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        applyMotion()
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.applyMotion()
            }
        }
        refreshHookStatus()
        startServer()
        startTicking()
        startDirectoryRefresh()
        miniPanel = MiniOfficePanelController(model: self)
        // 앱(NSApp)이 준비된 뒤에 미니를 띄웁니다 (init 때는 NSApp이 아직 없음). 조명도 시스템 모양을 읽을 수 있을 때 정합니다.
        DispatchQueue.main.async { [weak self] in
            self?.refreshLighting()
            self?.syncMiniPanel()
        }
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
        directoryTimer?.invalidate()
        server?.stop()
        EndpointFile.remove(at: endpointURL)
    }

    /// 무대를 흘리고 0.25초마다 연출 엔진의 tick을 돌립니다. 간격은 보이는 장면의 빈도를 따릅니다 (M6(1), 설계서 §8.3):
    /// 움직이는 장면이 보이면 30Hz, 잔잔하면 10Hz, 아무 장면도 안 보이면 4Hz.
    private func startTicking() {
        lastFrame = Date()
        scheduleTicks(interval: tickInterval)
        // 창이 가려지거나 다시 보이는 순간 바로 빈도를 맞춥니다 (다음 tick까지 기다리지 않음)
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePacing() }
            })
        }
        // 레티나 화면을 연결하거나 빼면 텍스처 굽는 배율을 다시 정합니다
        windowObservers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShapeBaker.screensChanged() }
        })
    }

    private func scheduleTicks(interval: TimeInterval) {
        timer?.invalidate()
        tickInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        // 느린 간격일 때는 다른 깨움과 묶일 수 있게 여유를 둡니다
        timer.tolerance = interval >= RenderPacer.hiddenTickInterval ? interval * 0.2 : 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 두 장면의 그리기 빈도와 모델 타이머 간격을 맞춥니다
    private func updatePacing(now: Date = Date()) {
        let settling = now < settleUntil
        let officeMotion = RenderPacer.motion(stageStore.stage), miniMotion = RenderPacer.motion(miniStore.stage)
        if officeMotion != .still || settling { officeBusyAt = now }
        if miniMotion != .still || settling { miniBusyAt = now }
        let office = RenderPacer.pace(
            visible: officeScene.isVisibleOnScreen, motion: officeMotion, settling: settling,
            quietFor: now.timeIntervalSince(officeBusyAt))
        let mini = RenderPacer.pace(
            visible: miniScene.isVisibleOnScreen, motion: miniMotion, settling: settling, quietFor: now.timeIntervalSince(miniBusyAt))
        officeScene.applyPace(office)
        miniScene.applyPace(mini)
        if (office != .paused) != officeVisible { officeVisible = office != .paused }
        if (mini != .paused) != miniVisible { miniVisible = mini != .paused }
        officeScene.renderOneFrame(now: now)
        miniScene.renderOneFrame(now: now)
        let interval = RenderPacer.tickInterval(for: [office, mini])
        if abs(interval - tickInterval) > 1e-6 { scheduleTicks(interval: interval) }
    }

    private var anySceneVisible: Bool {
        officeScene.isVisibleOnScreen || miniScene.isVisibleOnScreen
    }

    private func frame() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastFrame), 0)
        lastFrame = now
        PerfProbe.shared?.modelTicked()
        // 타이머가 느려도(4Hz) 무대 시간은 실제 시간대로, 0.1초 조각으로 나눠 흘립니다
        for step in RenderPacer.steps(dt: dt) {
            stageStore.floor.update(dt: step)
            miniStore.floor.update(dt: step)
        }
        tickAccumulator += dt
        if tickAccumulator >= 0.25 - 1e-3 {
            tickAccumulator = 0
            record(engine.tick(at: now))
            refreshLighting(now: now)
            refreshMiniFocus(now: now)
            syncMiniPanel()
            // 30초 넘게 안 보이는 장면은 가구 텍스처를 놓습니다 (닫힌 사무실 창이 미니만 보일 때 메모리를 잡고 있지 않게)
            officeScene.releaseFurnitureIfHidden(for: 30, now: now)
            miniScene.releaseFurnitureIfHidden(for: 30, now: now)
        }
        updatePacing(now: now)
        // 두 무대가 같은 지시를 받으므로 효과음은 한쪽에서만: 사무실 창이 보이면 사무실, 아니면 미니가 보일 때 미니
        let officeEvents = stageStore.floor.drainEvents()
        let miniEvents = miniStore.floor.drainEvents()
        let useMini = !officeScene.isVisibleOnScreen && miniScene.isVisibleOnScreen
        playSounds(useMini ? miniEvents : officeEvents)
    }

    /// 무대에서 나온 효과음을 재생기에 넘깁니다. 알림성 소리는 창이 안 보여도, 장식성 소리는 보일 때만 울립니다.
    private func playSounds(_ events: [StageEvent]) {
        var context: SoundContext?
        for event in events {
            guard case .sound(let cue, _) = event, soundSettings.isEnabled(cue.group) else { continue }
            if context == nil {
                // 집중 모드면 알림성 소리까지 줄입니다 (설계서 §11.3, 읽을 수 있을 때만)
                let focused = soundSettings.respectFocusMode && FocusDetector.isFocused
                let visible = officeScene.isVisibleOnScreen || miniScene.isVisibleOnScreen
                context = SoundContext(officeVisible: visible, focusModeActive: focused)
            }
            soundPlayer.play(cue, context: context!)
        }
    }

    private func receive(_ delivery: HookDelivery, hint: SessionHint?) {
        receivedHooks += 1
        lastHookAt = delivery.receivedAt
        do {
            let directives = try engine.handle(hookPayload: delivery.body, term: delivery.term, hint: hint, at: delivery.receivedAt)
            append(.hook, Self.summary(of: delivery, hint: hint))
            record(directives)
            PerfProbe.shared?.hookApplied(receivedAt: delivery.receivedAt, anyVisible: anySceneVisible)
            notifier.apply(HookTestScenario.withoutTestNotices(engine.drainNotices()))
        } catch {
            append(.system, "읽을 수 없는 훅을 받았어요: \(error)")
        }
        roster = Roster.make(from: engine.state, privacy: privacy)
        refreshMiniFocus(now: delivery.receivedAt)
        // 고른 직원이 퇴근하면 카드를 닫습니다
        if let selectedAgent, roster.row(for: selectedAgent) == nil { select(nil) }
        refreshStatusLine()
    }

    func select(_ id: AgentID?) {
        selectedAgent = id
        officeScene.selectedAgent = id
        if let id { acknowledge(id) }
        refreshStatusLine()
    }

    /// 캐릭터를 눌렀으면 그 세션의 응답을 본 것으로 칩니다 (M6(4): ✉ 확인 안 함 배지를 내림. "?" 답변 필요는 답할 때까지 그대로)
    private func acknowledge(_ id: AgentID) {
        guard let agent = engine.state.agents[id], agent.cue == .unread else { return }
        let directives = engine.acknowledge(agent.session, at: Date())
        guard !directives.isEmpty else { return }
        record(directives)
        roster = Roster.make(from: engine.state, privacy: privacy)
        refreshMiniFocus()
    }

    /// 현황 줄과 인스펙터 타임라인을 다시 만듭니다 (훅을 받았을 때, 고른 사람·디렉토리·표시 수준이 바뀌었을 때)
    private func refreshStatusLine() {
        // 행 순서는 사무실 화면과 같은 출처(보이는 행·숨긴 행)에서 가져옵니다 (M5(9))
        let plan = stageStore.floor.plan
        let line = StatusLine.make(
            state: engine.state, journal: engine.journal, privacy: privacy, selected: selectedAgent, folder: selectedFolder,
            rows: plan.rows.map(\.team), hiddenRows: plan.hiddenTeams)
        if line != statusLine { statusLine = line }
        let timeline = selectedAgent.map {
            AgentTimeline.make(agent: $0, state: engine.state, journal: engine.journal, privacy: privacy)
        } ?? .empty
        if timeline != inspectorTimeline { inspectorTimeline = timeline }
    }

    /// 연출 지시를 무대에 넘기고(화면에 보일 사람만, `OfficeFloor`), 로그에도 남깁니다.
    private func record(_ directives: [Directive]) {
        guard !directives.isEmpty else { return }
        stageStore.floor.apply(directives, engine: engine)
        miniStore.floor.apply(directives, engine: engine)
        // 받은 지시를 바로 30fps로 그립니다 (다음 tick을 기다리지 않음, 훅 → 화면 지연)
        settleUntil = Date().addingTimeInterval(RenderPacer.settleTime)
        updatePacing()
        updateHidden()
        for directive in directives {
            append(.directive, directive.description)
        }
    }

    private func updateHidden() {
        let hidden = stageStore.floor.plan.hiddenCount
        if hidden != hiddenOnScreen { hiddenOnScreen = hidden }
    }

    // MARK: - 디렉토리 선택 (2026-11-08)

    /// 데스크톱 앱 세션 정보 파일을 몇 초마다 다시 읽어 열려 있는 디렉토리 목록을 맞춥니다 (파일 읽기는 백그라운드).
    private func startDirectoryRefresh() {
        refreshDirectories()
        let timer = Timer(timeInterval: Self.directoryRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDirectories() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        directoryTimer = timer
    }

    func refreshDirectories() {
        guard !loadingDirectories else { return }
        loadingDirectories = true
        let directory = desktopSessions
        let desktopActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == DesktopAppFocuser.bundleID
        Task.detached(priority: .utility) {
            let readAt = Date()
            let records = directory.allRecords()
            let folders = DesktopSessionDirectory.openFolders(in: records)
            // 데스크톱 앱이 맨 앞이면 가장 최근에 연 세션을 "지금 보는 세션"으로 칩니다 (M6(4) 확인 안 함)
            let roll = DesktopResidents.roll(from: records, readAt: readAt, desktopAppActive: desktopActive)
            await MainActor.run {
                self.loadingDirectories = false
                if folders != self.directories { self.directories = folders }
                self.syncResidents(roll)
            }
        }
    }

    /// 데스크톱 앱에 열려 있는 세션을 사무실에 맞춥니다 (M5(5)): 새로 앉는 사람은 쉬는 중으로 조용히, 닫힌 세션은 퇴근.
    private func syncResidents(_ roll: ResidentRoll) {
        let now = Date()
        let before = Set(engine.state.agents.keys)
        let directives = engine.syncResidents(roll, at: now)
        guard !directives.isEmpty || roster != Roster.make(from: engine.state, privacy: privacy) else { return }
        let after = Set(engine.state.agents.keys)
        let arrived = after.subtracting(before).count, left = before.subtracting(after).count
        if arrived > 0 { append(.system, "데스크톱 앱에 열려 있는 세션 \(arrived)개를 쉬는 중으로 앉혔어요") }
        if left > 0 { append(.system, "데스크톱 앱에서 닫은 세션 \(left)명이 퇴근했어요") }
        record(directives)
        notifier.apply(HookTestScenario.withoutTestNotices(engine.drainNotices()))
        roster = Roster.make(from: engine.state, privacy: privacy)
        refreshMiniFocus(now: now)
        if let selectedAgent, roster.row(for: selectedAgent) == nil { select(nil) }
        refreshStatusLine()
    }

    /// 패널 "세션" 목록에 보여 줄 것 (고른 디렉토리의 메인과 그 서브만)
    var visibleRoster: Roster {
        selection.all ? roster : roster.filtered(folders: selection.folders)
    }

    /// 고른 디렉토리 (nil이면 모두)
    var selectedFolder: String? {
        selection.all ? nil : selection.folders.sorted().first
    }

    /// 드롭다운에 보여 줄 디렉토리: 데스크톱 앱에 열린 디렉토리 + (닫혔지만) 지금 고른 디렉토리
    var directoryOptions: [DesktopFolder] {
        var options = directories
        if let selected = selectedFolder, !options.contains(where: { $0.path == selected }) {
            options.append(DesktopFolder(path: selected, sessions: 0))
        }
        return options
    }

    /// 그 디렉토리에서 지금 사무실에 있는 메인 수와 사람 수
    func headcount(folder: String) -> (mains: Int, people: Int) {
        let teams = roster.teams.filter { $0.folder == folder }
        return (teams.count, teams.reduce(0) { $0 + $1.rows.count })
    }

    func selectAllFolders() {
        selectFolder(nil)
    }

    /// 디렉토리 하나만 고릅니다 (nil이면 모두: 새로 연 디렉토리도 자동으로 보임)
    func selectFolder(_ folder: String?) {
        setSelection(folder.map { FloorSelection(all: false, folders: [$0]) } ?? FloorSelection(all: true, folders: []))
    }

    private func setSelection(_ selection: FloorSelection) {
        self.selection = selection
        let defaults = UserDefaults.standard
        defaults.set(selection.all, forKey: Self.selectAllKey)
        defaults.set(selection.folders.sorted(), forKey: Self.selectedFoldersKey)
        stageStore.floor.setSelection(selection, engine: engine)
        updateHidden()
        if let selectedAgent, visibleRoster.row(for: selectedAgent) == nil { select(nil) }
        refreshStatusLine()
    }

    /// 사무실 영역 크기가 바뀜 (배율 1 유지, 들어가는 수를 다시 셈)
    private func setViewport(_ size: CGSize) {
        stageStore.floor.setViewport(width: Double(size.width), height: Double(size.height), engine: engine)
        updateHidden()
        refreshStatusLine()
    }

    // MARK: - 알림 (M5(3))

    func setNotificationSettings(_ settings: NotificationSettings) {
        notificationSettings = settings
        engine.notificationSettings = settings
        settings.save(to: .standard)
        // 처음 켜는 순간이 "알림이 필요할 때"입니다
        if (settings.permission || settings.completion || settings.reply), notificationAuthorization == .notDetermined {
            requestNotificationAuthorization()
        }
    }

    /// 알림 권한을 묻고, 이어서 집중 모드 상태 읽기도 묻습니다 (둘 다 아직 묻지 않았을 때만 시스템 창이 뜸)
    func requestNotificationAuthorization() {
        notifier.requestAuthorization { [weak self] in
            guard let self, self.focusAccess == .notDetermined else { return }
            self.requestFocusAccess()
        }
    }

    func refreshNotificationAuthorization() {
        notifier.refreshAuthorization()
        focusAccess = FocusDetector.access
    }

    func requestFocusAccess() {
        FocusDetector.requestAuthorization { [weak self] access in self?.focusAccess = access }
    }

    /// 지금 집중 모드인지 (설정 화면 표시용, 읽을 수 없으면 nil)
    var isFocusModeOn: Bool? {
        focusAccess == .authorized ? FocusDetector.isFocused : nil
    }

    /// 알림을 눌렀을 때: 데스크톱 앱 세션이면 Claude 데스크톱 앱을, CLI 세션이면 그 터미널을 앞으로 가져오고,
    /// 사무실 창이 열려 있으면 그 캐릭터를 고릅니다.
    private func open(_ target: Notifier.Target) {
        let part = target.session.flatMap { engine.state.parts[$0] }
        let agent = target.agent.flatMap { engine.state.agents[$0] }
        focus(hostSession: part?.hostSession ?? target.hostSession, term: agent?.term ?? target.term)
        if let id = target.agent, roster.row(for: id) != nil, isOfficeWindowOpen {
            if visibleRoster.row(for: id) == nil { selectAllFolders() }  // 다른 디렉토리를 보고 있었으면 모두로
            select(id)
        }
        append(.system, "알림 열기: \(target.hostSession != nil ? "Claude 데스크톱 앱" : TerminalFocuser.displayName(for: target.term) ?? "알 수 없는 터미널")")
    }

    /// 메뉴의 승인 대기 줄 "열기" 버튼 (알림을 누른 것과 같은 곳으로)
    func focusSession(of row: RosterRow) {
        focus(hostSession: row.hostSession, term: row.term)
    }

    /// 캐릭터·세션 줄 더블클릭, 인스펙터 [앱으로]/[터미널로] (M5(7)): 그 사람이 속한 세션의 Claude 앱이나 터미널을 앞으로.
    /// 서브에이전트도 자기가 속한 세션 기준이고(`RosterRow.hostSession`·`term`은 세션의 것), 미리 출근해 쉬는 데스크톱 세션도 앱으로 갑니다.
    func focusAgent(_ id: AgentID) {
        guard let row = roster.row(for: id) else { return }
        acknowledge(id)
        guard row.focusLabel != nil else {
            append(.system, "\(row.name): 앞으로 가져올 앱을 몰라요")
            return
        }
        focusSession(of: row)
        append(.system, "\(row.name) 세션으로 이동: \(row.hostSession != nil ? "Claude 데스크톱 앱" : TerminalFocuser.displayName(for: row.term) ?? "터미널")")
    }

    /// 마우스를 올린 캐릭터의 도움말 (M5(7)). 미니는 한 번 누르면 사무실 창이 열린다는 것도 알려 줍니다.
    func hoverHelp(for id: AgentID, mini: Bool) -> String? {
        guard let row = roster.row(for: id) else { return nil }
        let jump = row.focusLabel.map { "더블클릭하면 \($0) 이동" }
        if mini { return [row.name, "누르면 사무실 창", jump].compactMap { $0 }.joined(separator: " · ") }
        return [row.name, jump].compactMap { $0 }.joined(separator: " · ")
    }

    private func focus(hostSession: String?, term: String?) {
        if let hostSession {
            // 데스크톱 앱의 세션 이어 하기 딥링크로 그 세션 화면까지 엽니다 (M5(7b))
            DesktopAppFocuser.focus(session: hostSession)
        } else {
            TerminalFocuser.focus(term: term)
        }
    }

    // MARK: - 미니 사무실 (M5(4))

    /// 보여 줄 행을 다시 고릅니다 (훅을 받을 때, 0.25초마다): 답변 필요 → 완료 → 가장 마지막에 요청
    private func refreshMiniFocus(now: Date = Date()) {
        let next = MiniFocus.next(
            previous: miniFocus, state: engine.state, pinned: nil, autoSwitch: miniSettings.autoSwitch, now: now)
        if next.team != miniFocus.team { miniStore.floor.setSelection(.only(next.team), engine: engine) }
        if next != miniFocus { miniFocus = next }
    }

    /// 그 세션 직원이 마지막으로 요청을 받은 때 (미니 머리줄 "요청 받음")
    func promptedAt(_ row: RosterRow) -> Date? {
        row.role == .lead ? engine.state.parts[row.session]?.lastPromptAt : nil
    }

    /// 답변을 기다리는 까닭 ("승인 대기", "질문 답 대기", "계획 승인 대기")
    func waitLabel(of id: AgentID) -> String {
        if case .waitingForPermission(let call) = engine.state.agents[id]?.activity { return call?.waitLabel ?? "승인 대기" }
        return "승인 대기"
    }

    func setMiniSettings(_ settings: MiniOfficeSettings) {
        let old = miniSettings
        miniSettings = settings
        settings.save(to: .standard)
        if settings.enabled != old.enabled { syncMiniPanel() }
        if settings.opacity != old.opacity { miniPanel?.setOpacity(settings.opacity) }
        if settings.autoSwitch != old.autoSwitch { refreshMiniFocus() }
    }

    func setMiniEnabled(_ enabled: Bool) {
        var settings = miniSettings
        settings.enabled = enabled
        setMiniSettings(settings)
    }

    func resetMiniPosition() {
        miniPanel?.resetPosition()
    }

    private func setMiniViewport(_ size: CGSize) {
        miniStore.floor.setViewport(width: Double(size.width), height: OfficeLayout.minHeight, engine: engine)
    }

    /// 미니 사무실은 켜져 있고 사무실 창이 닫혀 있을 때만 보입니다 (사무실 창을 닫으면 다시 나타남).
    /// 최소화는 그냥 최소화입니다 (화면 확인: 최소화 버튼으로는 미니가 나타나지 않기를 원함).
    private func syncMiniPanel() {
        let wanted = miniSettings.enabled && !isOfficeWindowOpenOrMinimized && Date() >= miniHiddenUntil
        guard let miniPanel, wanted != miniPanel.isShown else { return }
        wanted ? miniPanel.show() : miniPanel.hide()
    }

    /// 사무실 창 → 미니 사무실: 미니를 켜고(꺼 두었어도) 사무실 창을 닫습니다
    func switchToMini() {
        miniHiddenUntil = .distantPast
        if !miniSettings.enabled { setMiniEnabled(true) }
        NSApp?.windows.first { $0.title == OfficeWindowView.title && $0.isVisible }?.close()
        syncMiniPanel()
    }

    /// 미니를 누르면(어디든) 미니를 숨기고 사무실 창을 엽니다. 캐릭터를 눌렀으면 그 사람을 고르고,
    /// 완료를 보여 주던 중이면 확인한 것으로 쳐서 사무실 창을 닫은 뒤에는 다음 순위를 보여 줍니다.
    func openOfficeFromMini(_ id: AgentID?) {
        acknowledgeMiniCompletion()
        miniHiddenUntil = Date().addingTimeInterval(1.5)
        miniPanel?.hide()
        openOfficeWindow()
        if let id, roster.row(for: id) != nil {
            if visibleRoster.row(for: id) == nil { selectAllFolders() }
            select(id)
        }
    }

    /// 미니에서 캐릭터를 더블클릭 (M5(7)): 미니는 그대로 두고 그 세션의 앱·터미널로. 완료를 보여 주던 중이면 확인한 것으로 칩니다.
    func focusFromMini(_ id: AgentID) {
        acknowledgeMiniCompletion()
        focusAgent(id)
    }

    /// 확인하지 않은 응답(✉)을 보여 주던 중이면 그 행의 응답을 모두 본 것으로 쳐서 다음 순위를 보여 줍니다 (M6(4))
    private func acknowledgeMiniCompletion() {
        guard miniFocus.tier == .completed, let team = miniFocus.team else { return }
        for agent in engine.state.agents(in: team) where agent.cue == .unread { acknowledge(agent.id) }
    }

    /// SwiftUI 장면의 창 열기 동작을 받아 둡니다 (메뉴바 아이콘·메뉴가 나타날 때)
    func registerOpenWindow(_ action: OpenWindowAction) {
        openOfficeWindowAction = { action(id: WindowID.office) }
    }

    func openOfficeWindow() {
        NSApp.activate()
        if let open = openOfficeWindowAction {
            open()
        } else if let window = NSApp.windows.first(where: { $0.title == OfficeWindowView.title }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 사무실 창이 떠 있거나 Dock에 최소화돼 있음 (닫지 않음)
    private var isOfficeWindowOpenOrMinimized: Bool {
        guard let app = NSApp else { return false }
        return app.windows.contains { $0.title == OfficeWindowView.title && ($0.isVisible || $0.isMiniaturized) }
    }

    private var isOfficeWindowOpen: Bool {
        guard let app = NSApp else { return false }
        return app.windows.contains { $0.title == OfficeWindowView.title && $0.isVisible && !$0.isMiniaturized }
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
        miniStore.privacy = level
        engine.privacy = level
        UserDefaults.standard.set(level.rawValue, forKey: PrivacyLevel.settingsKey)
        roster = Roster.make(from: engine.state, privacy: level)
        refreshStatusLine()
    }

    func setMotionSettings(_ settings: MotionSettings) {
        motionSettings = settings
        settings.save(to: UserDefaults.standard)
        applyMotion()
    }

    func setLightingMode(_ mode: LightingMode) {
        lightingMode = mode
        mode.save(to: UserDefaults.standard)
        refreshLighting()
    }

    /// 지금 밤인지 다시 판정해 두 장면에 알립니다 (M6(6)). 0.25초 tick마다 부르지만 계산은 시스템 모양·시각 읽기뿐이고,
    /// 바뀐 순간에만 장면이 크로스페이드하며 가구를 다시 굽습니다. 따로 타이머를 두지 않아 잠자기·시계 변경 뒤에도 맞습니다.
    private func refreshLighting(now: Date = Date()) {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let hour = Calendar.current.component(.hour, from: now)
        let night = lightingMode.isNight(systemDark: dark, hour: hour)
        let lighting: Lighting = night ? .night : .day
        guard night != isNight || stageStore.lighting != lighting else { return }
        isNight = night
        officeScene.setLighting(lighting)
        miniScene.setLighting(lighting)
        // 크로스페이드 동안 30fps로 그립니다
        settleUntil = max(settleUntil, now.addingTimeInterval(OfficeScene.lightingFade + 0.1))
        updatePacing(now: now)
    }

    /// 지금 동작을 줄이는지 (설정과 macOS 손쉬운 사용 값으로 정함)
    var reducesMotion: Bool { motionSettings.reducesMotion(systemReduceMotion: systemReduceMotion) }

    /// 두 무대(사무실 창·미니)에 동작 줄이기를 알립니다: 걷기 대신 순간이동, 제스처 생략
    private func applyMotion() {
        let on = reducesMotion
        stageStore.floor.setReducedMotion(on)
        miniStore.floor.setReducedMotion(on)
    }

    func refreshHookStatus() {
        hookStatus = installer.status()
        hookScript = installer.scriptState()
    }

    /// 설정 → 연동의 훅 상태 (M5(8)). `now`가 바뀌면 "12초 전"도 바뀝니다.
    func hookHealth(now: Date = Date()) -> HookHealth {
        let port: UInt16?, error: String?
        switch serverState {
        case .running(let p): (port, error) = (p, nil)
        case .stopped: (port, error) = (nil, nil)
        case .failed(let message): (port, error) = (nil, message)
        }
        return HookHealth.evaluate(
            .init(status: hookStatus, script: hookScript, port: port, serverError: error, lastEventAt: lastHookAt,
                  eventCount: receivedHooks),
            now: now)
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

    /// "테스트 이벤트 보내기" (M5(8)): 설치된 훅 스크립트를 실제로 실행해 가짜 세션이 잠깐 출근했다 퇴근하게 합니다.
    /// 스크립트 → 엔드포인트 파일 → 서버 → 사무실 경로를 모두 지나며, 이 세션의 알림은 띄우지 않습니다.
    func sendTestEvents() {
        guard !isSendingTest else { return }
        isSendingTest = true
        let script = installer.scriptURL
        let before = receivedHooks
        let steps = HookTestScenario.steps(session: HookTestScenario.sessionID(at: Date()))
        installMessage = "테스트 세션이 출근하는 중이에요… 사무실 창이나 미니 사무실에서 \"\((HookTestScenario.folder as NSString).lastPathComponent)\" 행을 보세요."
        Task.detached(priority: .userInitiated) {
            for step in steps {
                if step.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000)) }
                if let error = Self.runHookScript(script, payload: step.payload) {
                    await MainActor.run {
                        self.isSendingTest = false
                        self.installMessage = "훅 스크립트를 실행하지 못했어요: \(error). \"다시 설치\"를 눌러 보세요."
                        self.refreshHookStatus()
                    }
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                self.isSendingTest = false
                let arrived = self.receivedHooks - before
                self.installMessage = arrived >= steps.count
                    ? "연결 확인 완료! 테스트 이벤트 \(arrived)개가 모두 도착했어요."
                    : "테스트 이벤트가 \(steps.count)개 중 \(arrived)개만 도착했어요. 훅을 다시 설치하거나 서버를 다시 시작해 보세요."
            }
        }
    }

    /// 훅 스크립트를 한 번 실행합니다 (Claude Code가 하듯 stdin으로 페이로드). 실행하지 못하면 까닭을 돌려줍니다.
    nonisolated private static func runHookScript(_ script: URL, payload: String) -> String? {
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
            return process.terminationStatus == 0 ? nil : "종료 코드 \(process.terminationStatus)"
        } catch {
            return "\(error)"
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
