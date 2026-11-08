import AppKit
import OfficeCore
import OfficeStage
import SpriteKit
import SwiftUI

/// 미니 사무실 설정 (설계서 §10.1, M5(4))
struct MiniOfficeSettings: Equatable {
    /// 켜기/끄기 (메뉴바·설정·패널의 ✕)
    var enabled: Bool
    /// 승인 대기가 생기면 그 행으로 바꾸기
    var autoSwitch: Bool
    /// 패널 투명도 (0.5~1)
    var opacity: Double

    static let enabledKey = "mini.enabled"
    static let autoSwitchKey = "mini.autoSwitch"
    static let opacityKey = "mini.opacity"

    init(enabled: Bool = true, autoSwitch: Bool = true, opacity: Double = 1) {
        self.enabled = enabled
        self.autoSwitch = autoSwitch
        self.opacity = opacity
    }

    init(defaults: UserDefaults) {
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        autoSwitch = defaults.object(forKey: Self.autoSwitchKey) as? Bool ?? true
        opacity = min(1, max(0.5, defaults.object(forKey: Self.opacityKey) as? Double ?? 1))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(autoSwitch, forKey: Self.autoSwitchKey)
        defaults.set(opacity, forKey: Self.opacityKey)
    }
}

/// 미니 사무실 패널 (M5(4) v2): 화면 구석에 떠 있는 작은 창.
///
/// - 포커스를 빼앗지 않고(nonactivating), 모든 Space와 전체 화면 앱 위에도 보입니다.
/// - 위 24pt는 머리줄(SwiftUI), 아래는 메인 + 서브 2명 띠 사무실(SpriteKit, 배율 1). 크기는 390×204 고정입니다.
/// - 기본 위치는 화면 오른쪽 아래(가장자리에서 16pt). 디스플레이마다 마지막 위치를 기억하고, 가장자리 40pt 안에 놓으면 붙입니다.
@MainActor
final class MiniOfficePanelController: NSObject, NSWindowDelegate {
    static let title = "Claude Office 미니 사무실"
    static let margin: CGFloat = 16
    static let snapDistance: CGFloat = 40

    private weak var model: AppModel?
    private var panel: NSPanel?
    private var settleWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    /// 프로그램이 창을 옮기는 중 (저장·붙이기를 다시 부르지 않음)
    private var placing = false

    init(model: AppModel) {
        self.model = model
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
    }

    var isShown: Bool { panel?.isVisible == true }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { place(panel, frame: initialFrame()) }
        panel.alphaValue = CGFloat(model?.miniSettings.opacity ?? 1)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func setOpacity(_ opacity: Double) {
        panel?.alphaValue = CGFloat(opacity)
    }

    /// 설정의 "기본 위치로": 지금 화면의 오른쪽 아래
    func resetPosition() {
        guard let panel else { return }
        if let id = Self.displayID(panel.screen) { UserDefaults.standard.removeObject(forKey: Self.frameKey(id)) }
        place(panel, frame: defaultFrame(on: panel.screen ?? NSScreen.main))
        save()
    }

    static var size: NSSize { NSSize(width: CGFloat(MiniOffice.panelWidth), height: CGFloat(MiniOffice.panelHeight)) }

    // MARK: - 만들기

    private func makePanel() -> NSPanel {
        let size = Self.size
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.title = Self.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.delegate = self
        if let model { panel.contentView = Self.content(model: model, size: size) }
        model?.miniScene.onWindowDragged = { [weak self] in self?.settle(after: 0) }
        return panel
    }

    private static func content(model: AppModel, size: NSSize) -> NSView {
        let header = CGFloat(MiniOffice.headerHeight)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let sprite = FirstMouseSKView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - header))
        sprite.autoresizingMask = [.width, .height]
        sprite.preferredFramesPerSecond = 30
        sprite.allowsTransparency = false
        sprite.presentScene(model.miniScene)
        let top = FirstMouseHostingView(rootView: MiniHeaderView(model: model))
        top.frame = NSRect(x: 0, y: size.height - header, width: size.width, height: header)
        top.autoresizingMask = [.width, .minYMargin]
        container.addSubview(sprite)
        container.addSubview(top)
        return container
    }

    // MARK: - 위치와 크기

    private static func displayID(_ screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func frameKey(_ id: UInt32) -> String { "mini.frame.\(id)" }

    /// 열 때: 지금 화면(메뉴바가 있는 화면)에서 기억해 둔 자리, 없거나 화면 밖이면 오른쪽 아래
    private func initialFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let id = Self.displayID(screen), let saved = UserDefaults.standard.string(forKey: Self.frameKey(id)) {
            let frame = NSRect(origin: NSRectFromString(saved).origin, size: Self.size)
            if let visible = screen?.visibleFrame, visible.contains(frame) { return frame }
        }
        return defaultFrame(on: screen)
    }

    private func defaultFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.maxX - Self.margin - Self.size.width, y: visible.minY + Self.margin, width: Self.size.width, height: Self.size.height)
    }

    private func place(_ panel: NSPanel, frame: NSRect) {
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
    }

    /// 해상도가 바뀌거나 모니터를 빼서 화면 밖으로 나가면 그 화면에서 쓰던 자리(없으면 기본 자리)로
    private func keepOnScreen() {
        guard let panel, panel.isVisible else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard !visible.contains(panel.frame) else { return }
        place(panel, frame: initialFrame())
    }

    /// 옮긴 뒤 잠깐 기다렸다가(끄는 중이면 다시 미룸) 가장자리에 붙이고 저장합니다
    private func settle(after delay: TimeInterval = 0.3) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons != 0 { return self.settle() }
                self.snap()
                self.save()
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func snap() {
        guard let panel, let visible = panel.screen?.visibleFrame else { return }
        var frame = panel.frame
        if abs(frame.minX - visible.minX) < Self.snapDistance { frame.origin.x = visible.minX + Self.margin }
        if abs(visible.maxX - frame.maxX) < Self.snapDistance { frame.origin.x = visible.maxX - Self.margin - frame.width }
        if abs(frame.minY - visible.minY) < Self.snapDistance { frame.origin.y = visible.minY + Self.margin }
        if abs(visible.maxY - frame.maxY) < Self.snapDistance { frame.origin.y = visible.maxY - Self.margin - frame.height }
        if frame != panel.frame { place(panel, frame: frame) }
    }

    private func save() {
        guard let panel, let id = Self.displayID(panel.screen) else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey(id))
    }

    func windowDidMove(_ notification: Notification) {
        if !placing { settle() }
    }

    func windowDidResize(_ notification: Notification) {
        if !placing { settle() }
    }
}

/// 비활성 패널에서도 첫 클릭이 바로 캐릭터·버튼에 가도록
final class FirstMouseSKView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 미니 사무실 머리줄 (24pt, v2): 지금 행(누르면 고정할 행 고르기)과 그 상태, 다른 메인 칩, [앱으로]/[터미널로], ✕
///
/// - 답변 필요: 노랑, "서브3 승인 대기 12초째" (질문이면 "질문 답 대기", 계획이면 "계획 승인 대기")
/// - 완료: 초록, "✓ 응답 완료 · 2분 전". [앱으로]를 누르면 확인한 것으로 쳐서 다음 순위로 넘어갑니다.
/// - 그 밖: "작업 중 · 요청 5분 전" / "쉬는 중 · 요청 1시간 전"
struct MiniHeaderView: View {
    let model: AppModel

    private static let ink = Color(hex: 0x3A3247)
    private static let paper = Color(hex: 0xFFF8EC)
    private static let done = Color(hex: 0xCFEBD9)
    private static let maxChips = 2

    var body: some View {
        let roster = model.roster
        let focus = model.miniFocus
        let current = roster.teams.first { $0.id == focus.team }
        let waiting = (current?.rows ?? []).filter { $0.status == .waitingForPermission }.sorted { $0.since < $1.since }
        let main = current?.rows.first(where: \.isMain)
        let others = roster.teams.filter { $0.id != current?.id }
            .sorted { Self.rank(focus.tiers[$0.id]) < Self.rank(focus.tiers[$1.id]) }
        let button: RosterRow? = focus.tier == .answer ? waiting.first : focus.tier == .completed ? main : nil
        HStack(spacing: 5) {
            teamMenu(current, roster: roster)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(statusText(focus: focus, waiting: waiting, main: main, now: context.date))
                    .font(.system(size: 10.5, weight: focus.tier == .answer || focus.tier == .completed ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(-1)
            Spacer(minLength: 0)
            ForEach(others.prefix(Self.maxChips)) { team in
                chip(team, tier: focus.tiers[team.id] ?? .none)
            }
            if others.count > Self.maxChips {
                Text("+\(others.count - Self.maxChips)")
                    .font(.system(size: 10))
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(.white))
                    .overlay(Capsule().stroke(Color(hex: 0xCFC6D9)))
                    .help(others.dropFirst(Self.maxChips).map(\.label).joined(separator: "\n"))
            }
            if let row = button, row.canFocus {
                Button(row.hostSession != nil ? "앱으로" : "터미널로") { model.openFromMiniHeader(row) }
                    .font(.system(size: 10.5, weight: .semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white))
                    .overlay(Capsule().stroke(Color(hex: focus.tier == .answer ? 0xE2B93B : 0x5DBB7A)))
                    .fixedSize()
            }
            Button {
                model.setMiniEnabled(false)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("미니 사무실 끄기 (메뉴바에서 다시 켤 수 있어요)")
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(focus.tier == .answer ? Palette.attention : focus.tier == .completed ? Self.done : Self.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xD8CDBE)).frame(height: 1) }
        .environment(\.colorScheme, .light)
    }

    /// 다른 메인 칩 순서: 답변 필요 → 완료 → 그 밖
    private static func rank(_ tier: MiniFocus.Tier?) -> Int {
        switch tier {
        case .answer: 0
        case .completed: 1
        case .requested: 2
        default: 3
        }
    }

    private func teamMenu(_ current: RosterTeam?, roster: Roster) -> some View {
        Menu {
            Button {
                model.pinMini(nil)
            } label: {
                let title = "자동 (답변 필요 → 완료 → 최근 요청)"
                if model.miniPinned == nil { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
            if !roster.teams.isEmpty { Divider() }
            ForEach(roster.teams) { team in
                Button {
                    model.pinMini(team.id)
                } label: {
                    if model.miniPinned == team.id { Label(team.label, systemImage: "checkmark") } else { Text(team.label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let current { Circle().fill(Palette.team(current.colorIndex)).frame(width: 7, height: 7) }
                Text(current?.label ?? "아직 출근한 직원이 없어요")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if model.miniPinned != nil { Image(systemName: "pin.fill").font(.system(size: 8)) }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("미니 사무실에 보여 줄 메인 (고르면 고정, 자동이면 답변 필요 → 완료 → 최근 요청 순)")
    }

    private func chip(_ team: RosterTeam, tier: MiniFocus.Tier) -> some View {
        let waiting = team.rows.filter { $0.status == .waitingForPermission }.count
        let number = team.mainName.replacingOccurrences(of: "메인", with: "")
        let (icon, fill, stroke): (String, Color, UInt32) = switch tier {
        case .answer: ("?", Palette.attention, 0xE2B93B)
        case .completed: ("✓", Self.done, 0x5DBB7A)
        default: ("", .white, 0xCFC6D9)
        }
        return Button {
            model.pinMini(team.id)
        } label: {
            HStack(spacing: 3) {
                Circle().fill(Palette.team(team.colorIndex)).frame(width: 6, height: 6)
                Text(icon + (number.isEmpty ? "메인" : number)).font(.system(size: 10, weight: tier == .requested || tier == .none ? .regular : .bold))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(Color(hex: stroke)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("\(team.label) · \(team.rows.count)명\(Self.tierHelp(tier, waiting: waiting)) (누르면 이 메인으로 고정)")
    }

    private static func tierHelp(_ tier: MiniFocus.Tier, waiting: Int) -> String {
        switch tier {
        case .answer: " · 답변 필요 \(waiting)명"
        case .completed: " · 응답 완료"
        case .requested: " · 작업 중"
        case .none: ""
        }
    }

    private func statusText(focus: MiniFocus, waiting: [RosterRow], main: RosterRow?, now: Date) -> String {
        switch focus.tier {
        case .answer:
            guard let first = waiting.first else { return "답변 필요" }
            let elapsed = StatusLine.elapsed(now.timeIntervalSince(first.since)).map { " \($0)" } ?? ""
            let more = waiting.count > 1 ? " 외 \(waiting.count - 1)명" : ""
            return "\(first.title.label) \(model.waitLabel(of: first.id))\(elapsed)\(more)"
        case .completed:
            return "✓ 응답 완료 · \(Self.ago(focus.tierAt, now: now))"
        case .requested:
            let resting = main.map { $0.status == .idle || $0.status == .waitingForInput } ?? false
            return "\(resting ? "쉬는 중" : "작업 중") · 요청 \(Self.ago(focus.tierAt, now: now))"
        case .none:
            return ""
        }
    }

    /// "방금", "3분 전", "2시간 전"
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "방금" }
        if seconds < 3600 { return "\(seconds / 60)분 전" }
        return "\(seconds / 3600)시간 전"
    }
}
