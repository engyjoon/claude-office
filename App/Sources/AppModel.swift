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
    /// 알림 설정 (설계서 §10 알림, M5(3)). 승인 대기 켬, 응답 완료 끔이 기본.
    private(set) var notificationSettings: NotificationSettings
    /// macOS 알림 권한 상태
    private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    /// 집중 모드 상태를 읽을 수 있는지
    private(set) var focusAccess: FocusDetector.Access = .notDetermined
    /// 미니 사무실 (M5(4)): 지금 보여 주는 행과 그 까닭, 사용자가 고정한 행, 설정
    private(set) var miniFocus: MiniFocus = .empty
    /// 미니에서 확인한 완료 (세션 → 확인한 완료 시각). 확인한 완료는 우선순위 ②에서 내려갑니다.
    private(set) var miniAcknowledged: [SessionID: Date] = [:]
    /// 미니를 눌러 사무실 창을 여는 중 (창이 뜨기 전에 미니가 다시 나타나지 않게)
    @ObservationIgnored private var miniHiddenUntil = Date.distantPast
    private(set) var miniSettings: MiniOfficeSettings

    @ObservationIgnored private var engine: OfficeEngine
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var directoryTimer: Timer?
    @ObservationIgnored private var loadingDirectories = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    let installer = HookInstaller()
    let endpointURL = EndpointFile.defaultURL()
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

    private static let privacyKey = "privacy"
    private static let selectAllKey = "office.selection.all"
    private static let selectedFoldersKey = "office.selection.folders"
    /// 디렉토리 목록을 새로 읽는 간격
    private static let directoryRefreshInterval: TimeInterval = 5
    private static let maxLogEntries = 600

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.privacyKey).flatMap(PrivacyLevel.init(rawValue:)) ?? .detailed
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
        officeScene.onViewportChange = { [weak self] size in self?.setViewport(size) }
        miniScene.onSelect = { [weak self] id in self?.openOfficeFromMini(id) }
        miniScene.onViewportChange = { [weak self] size in self?.setMiniViewport(size) }
        notifier.onAuthorizationChange = { [weak self] status in self?.notificationAuthorization = status }
        notifier.onOpen = { [weak self] target in self?.open(target) }
        focusAccess = FocusDetector.access
        refreshHookStatus()
        startServer()
        startTicking()
        startDirectoryRefresh()
        miniPanel = MiniOfficePanelController(model: self)
        // 앱(NSApp)이 준비된 뒤에 미니를 띄웁니다 (init 때는 NSApp이 아직 없음)
        DispatchQueue.main.async { [weak self] in self?.syncMiniPanel() }
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
        stageStore.floor.update(dt: dt)
        miniStore.floor.update(dt: dt)
        tickAccumulator += dt
        if tickAccumulator >= 0.25 {
            tickAccumulator = 0
            record(engine.tick(at: now))
            refreshMiniFocus(now: now)
            syncMiniPanel()
            officeScene.restartIfStalled()
            miniScene.restartIfStalled()
        }
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
        do {
            let directives = try engine.handle(hookPayload: delivery.body, term: delivery.term, hint: hint, at: delivery.receivedAt)
            append(.hook, Self.summary(of: delivery, hint: hint))
            record(directives)
            notifier.apply(engine.drainNotices())
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
        refreshStatusLine()
    }

    /// 현황 줄을 다시 만듭니다 (훅을 받았을 때, 고른 사람·디렉토리·표시 수준이 바뀌었을 때)
    private func refreshStatusLine() {
        let line = StatusLine.make(
            state: engine.state, journal: engine.journal, privacy: privacy, selected: selectedAgent, folder: selectedFolder)
        if line != statusLine { statusLine = line }
    }

    /// 연출 지시를 무대에 넘기고(화면에 보일 사람만, `OfficeFloor`), 로그에도 남깁니다.
    private func record(_ directives: [Directive]) {
        guard !directives.isEmpty else { return }
        stageStore.floor.apply(directives, engine: engine)
        miniStore.floor.apply(directives, engine: engine)
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
        RunLoop.main.add(timer, forMode: .common)
        directoryTimer = timer
    }

    func refreshDirectories() {
        guard !loadingDirectories else { return }
        loadingDirectories = true
        let directory = desktopSessions
        Task.detached(priority: .utility) {
            let readAt = Date()
            let records = directory.allRecords()
            let folders = DesktopSessionDirectory.openFolders(in: records)
            let roll = DesktopResidents.roll(from: records, readAt: readAt)
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
        notifier.apply(engine.drainNotices())
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
    }

    // MARK: - 알림 (M5(3))

    func setNotificationSettings(_ settings: NotificationSettings) {
        notificationSettings = settings
        engine.notificationSettings = settings
        settings.save(to: .standard)
        // 처음 켜는 순간이 "알림이 필요할 때"입니다
        if (settings.permission || settings.completion), notificationAuthorization == .notDetermined {
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

    private func focus(hostSession: String?, term: String?) {
        if hostSession != nil {
            // 특정 세션까지 여는 공개된 방법이 없어 앱만 앞으로 가져옵니다
            DesktopAppFocuser.focus()
        } else {
            TerminalFocuser.focus(term: term)
        }
    }

    // MARK: - 미니 사무실 (M5(4))

    /// 보여 줄 행을 다시 고릅니다 (훅을 받을 때, 0.25초마다): 답변 필요 → 완료 → 가장 마지막에 요청
    private func refreshMiniFocus(now: Date = Date()) {
        miniAcknowledged = miniAcknowledged.filter { engine.state.parts[$0.key]?.completedAt == $0.value }
        let next = MiniFocus.next(
            previous: miniFocus, state: engine.state, pinned: nil, acknowledged: miniAcknowledged,
            autoSwitch: miniSettings.autoSwitch, now: now)
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
        if miniFocus.tier == .completed, let team = miniFocus.team, let main = engine.state.main(of: team),
            let done = engine.state.parts[main.session]?.completedAt
        {
            miniAcknowledged[main.session] = done
            refreshMiniFocus()
        }
        miniHiddenUntil = Date().addingTimeInterval(1.5)
        miniPanel?.hide()
        openOfficeWindow()
        if let id, roster.row(for: id) != nil {
            if visibleRoster.row(for: id) == nil { selectAllFolders() }
            select(id)
        }
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
        UserDefaults.standard.set(level.rawValue, forKey: Self.privacyKey)
        roster = Roster.make(from: engine.state, privacy: level)
        refreshStatusLine()
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
