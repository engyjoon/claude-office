import OfficeCore
import OfficeStage
import SpriteKit
import SwiftUI

@main
struct ClaudeOfficeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(
                roster: model.roster, registerOpenWindow: { model.registerOpenWindow($0) },
                registerOpenSettings: { model.registerOpenSettings($0) })
        }
        .menuBarExtraStyle(.window)

        Window(OfficeWindowView.title, id: WindowID.office) {
            OfficeWindowView(model: model)
        }
        // 크기 고정 (M5(9)): 창은 내용 크기 그대로라 가장자리로 늘리거나 줄일 수 없고, 예전에 늘려 둔 크기도 이 크기로 돌아옵니다.
        // 세션 패널을 숨기거나 보일 때만 너비가 패널 폭만큼 바뀝니다.
        .windowResizability(.contentSize)

        Window(EventLogView.title, id: WindowID.eventLog) {
            EventLogView(model: model)
        }
        .defaultSize(width: 680, height: 440)

        Settings {
            SettingsView(model: model)
        }
    }
}

enum WindowID {
    static let office = "office"
    static let eventLog = "event-log"
}

/// 사무실 창 (M3). 왼쪽은 사무실과 그 아래 세 줄 실시간 현황, 오른쪽은 디렉토리·세션 패널.
///
/// 크기는 고정입니다 (M5(9)): 사무실 영역은 배율 1에서 3행이 다 들어가는 기본 크기(`OfficeWindowSize`), 그 아래 현황 줄,
/// 오른쪽 패널. 화면이 이보다 작으면 화면 안에 들어가게 사무실 영역만 줄이고(사무실은 축소해 그림), 넘치는 행·서브는 "+N".
struct OfficeWindowView: View {
    let model: AppModel
    @AppStorage("office.showStaffPanel") private var showStaffPanel = true
    @State private var escapeMonitor: Any?
    /// 창이 놓인 화면의 쓸 수 있는 크기와 제목 막대 높이 (화면이 작을 때 줄이려고)
    @State private var screen = OfficeWindowSize.Screen.unknown

    var body: some View {
        let office = OfficeWindowSize.office(screen: screen, panel: showStaffPanel)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                OfficeSpriteView(scene: model.officeScene)
                    .frame(width: office.width, height: office.height)
                    .background(Color(red: 0.945, green: 0.902, blue: 0.839))
                    .overlay(alignment: .topTrailing) {
                        // 캐릭터(또는 세션 패널의 줄)를 고르면 인스펙터를 보여줍니다 (M5(7)). 빈 곳 클릭·✕·Esc로 닫습니다.
                        if let id = model.selectedAgent, let row = model.roster.row(for: id), let team = model.roster.team(of: id) {
                            AgentCard(
                                row: row, team: team, privacy: model.privacy, timeline: model.inspectorTimeline,
                                agentDescription: model.agentDescription(for: row, in: team),
                                onSelect: { model.select($0) },
                                onFocus: { model.focusAgent(id) },
                                onClose: { model.select(nil) })
                                .padding(12)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: model.selectedAgent)
                // 사무실 바로 아래 세 줄 (사무실 영역은 줄어들지 않고, 창 높이에 이만큼 더합니다)
                StatusLineView(line: model.statusLine)
                    .frame(width: office.width)
            }
            if showStaffPanel {
                Divider()
                StaffPanel(model: model)
            }
        }
        // 창이 안 보이면 현황 줄·인스펙터의 시계 글자를 멈춥니다 (M6(1))
        .environment(\.liveClock, model.officeVisible)
        // 내용 크기를 못 박아 창 크기를 고정합니다 (`.windowResizability(.contentSize)`)
        .frame(width: office.width + (showStaffPanel ? OfficeWindowSize.panel : 0), height: office.height + StatusLineView.height)
        .background(WindowAccessor { window in
            OfficeWindowSize.lock(window)
            let next = OfficeWindowSize.Screen(window: window)
            if next != screen {
                // 화면 크기 정보가 바뀐 횟수 (디버그 계측: 창 크기·레이아웃이 되풀이되는지 보려고)
                PerfProbe.shared?.count("office.screenChanged")
                screen = next
            }
        })
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // 사무실 창 → 미니 사무실 (M5(4)): 사무실 창을 닫고 화면 구석의 미니로. 미니를 누르면 다시 사무실 창.
                Button {
                    model.switchToMini()
                } label: {
                    Label("미니 사무실로", systemImage: "pip.enter")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .help("사무실 창을 닫고 화면 구석의 미니 사무실로 봐요 (⇧⌘M). 미니를 누르면 다시 사무실 창이 열려요.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showStaffPanel.toggle()
                } label: {
                    Label("세션 패널", systemImage: "sidebar.right")
                }
                .help(showStaffPanel ? "디렉토리·세션 패널 숨기기" : "디렉토리·세션 패널 보기")
            }
        }
        // SpriteKit 뷰가 키 입력을 먼저 받아서 onExitCommand로는 Esc가 오지 않습니다. 창 단위로 가로챕니다.
        .onAppear {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, model.selectedAgent != nil,
                      event.window?.title == OfficeWindowView.title else { return event }
                model.select(nil)
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }
    }

    static let title = "Claude Office 사무실"
}

/// 사무실 창의 고정 크기 (M5(9))
enum OfficeWindowSize {
    /// 사무실 영역 기본 크기: 배율 1에서 3행이 다 들어가는 사무실(`OfficeLayout.defaultWidth`×`defaultHeight`) + 둘레 여백
    static let office = CGSize(
        width: OfficeLayout.defaultWidth + OfficeLayout.padding * 2, height: OfficeLayout.defaultHeight + OfficeLayout.padding * 2)
    /// 오른쪽 패널 폭 (구분선 포함)
    static let panel: CGFloat = StaffPanel.width + 1
    /// 화면이 아주 작아도 이보다는 줄이지 않습니다
    static let minimumOffice = CGSize(width: 480, height: 300)

    /// 창이 놓인 화면
    struct Screen: Equatable {
        /// 메뉴 막대·Dock을 뺀 크기 (모르면 nil: 기본 크기 그대로)
        var visible: CGSize?
        /// 제목 막대 + 도구 막대 높이
        var chrome: CGFloat

        static let unknown = Screen(visible: nil, chrome: 52)

        @MainActor init(window: NSWindow) {
            visible = (window.screen ?? NSScreen.main)?.visibleFrame.size
            let measured = window.frame.height - window.contentLayoutRect.height
            chrome = measured > 0 ? measured.rounded() : Self.unknown.chrome
        }

        init(visible: CGSize?, chrome: CGFloat) {
            self.visible = visible
            self.chrome = chrome
        }
    }

    /// 사무실 영역 크기: 기본 크기, 화면이 작으면 화면 안에 들어가게 줄인 크기
    static func office(screen: Screen, panel showsPanel: Bool) -> CGSize {
        guard let visible = screen.visible else { return office }
        let width = min(office.width, visible.width - (showsPanel ? panel : 0))
        let height = min(office.height, visible.height - screen.chrome - StatusLineView.height)
        return CGSize(width: max(minimumOffice.width, width.rounded(.down)), height: max(minimumOffice.height, height.rounded(.down)))
    }

    /// 가장자리 크기 조절 외에 초록 버튼(최대화·전체 화면)도 막습니다
    @MainActor static func lock(_ window: NSWindow) {
        if !window.collectionBehavior.contains(.fullScreenNone) {
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
        }
        if let zoom = window.standardWindowButton(.zoomButton), zoom.isEnabled { zoom.isEnabled = false }
    }
}

/// 뷰가 붙은 창을 알려 줍니다 (붙을 때, 화면을 옮길 때, 다시 그릴 때)
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowAccessorView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { DispatchQueue.main.async { onWindow(window) } }
    }
}

final class WindowAccessorView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?
    private var screenObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in self?.onWindow?(window) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWindow?(window) }
        }
    }
}

/// 사무실 장면을 담는 SpriteKit 뷰. 같은 장면을 창을 닫았다 열 때마다 새 뷰에 붙이므로,
/// 창이 닫히면 장면을 떼어 내고(옛 뷰에 붙은 채 멈추지 않게) 열릴 때 멈춤을 풀어 붙입니다 (M5(4) 화면 확인: 캐릭터가 멈춤).
struct OfficeSpriteView: NSViewRepresentable {
    let scene: OfficeScene

    func makeNSView(context: Context) -> SKView {
        let view = OfficeSKView()
        view.limitDrawables()
        view.preferredFramesPerSecond = 30
        // 사무실은 거의 다 화면 안이라, 매 프레임 노드마다 화면 밖인지 재는 비용이 아낄 것보다 큽니다 (M6(1))
        view.shouldCullNonVisibleNodes = false
        view.presentScene(scene)
        scene.resumeIfPaused()
        return view
    }

    func updateNSView(_ view: SKView, context: Context) {
        if view.scene !== scene { view.presentScene(scene) }
        scene.resumeIfPaused()
    }

    static func dismantleNSView(_ view: SKView, coordinator: ()) {
        view.presentScene(nil)
        // 장면을 뗀 SKView도 멈추지 않으면 디스플레이 링크가 계속 돌아 아무것도 안 그리면서 vsync마다 메인 스레드를 깨웁니다
        // (M6(1) 측정: 사무실 창을 닫은 뒤 CPU 4%, 초당 180번 깨움)
        view.isPaused = true
    }
}

/// 창에 붙을 때 마우스 이동(말풍선 전체 보기)을 받게 하고 멈춤을 풉니다. 창에서 떨어지면 멈춥니다 (디스플레이 링크가 돌지 않게).
///
/// 키보드 (M6(7)): 창을 열면 장면이 키보드 초점을 받습니다.
/// - ← → · Tab ⇧Tab: 앞뒤 사람 고르기 (행 → 책상 순서). Tab은 끝을 넘으면 다음 조작(세션 패널)으로 초점을 넘깁니다. ⌃Tab은 바로 넘김.
/// - ↑ ↓: 윗행·아랫행의 가장 가까운 책상
/// - Return·Enter: 그 세션으로 이동 (더블클릭과 같음)
/// - Esc: 고르기 풀기 (창 단위로 `OfficeWindowView`가 받음)
final class OfficeSKView: AccessibleSKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            isPaused = true
            return
        }
        window.acceptsMouseMovedEvents = true
        limitDrawables()
        (scene as? OfficeScene)?.resumeIfPaused()
        focusRingType = .exterior
        // 처음 열 때 아무것도 초점이 없으면 장면이 받습니다 (바로 화살표로 고를 수 있게)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            if window.firstResponder === window || window.firstResponder == nil { window.makeFirstResponder(self) }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override func drawFocusRingMask() {
        NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }

    override func keyDown(with event: NSEvent) {
        guard let scene = officeScene else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 48:  // Tab
            if modifiers.contains(.control) || modifiers.contains(.option) {
                modifiers.contains(.shift) ? window?.selectPreviousKeyView(self) : window?.selectNextKeyView(self)
            } else if !scene.moveSelection(modifiers.contains(.shift) ? .previous : .next) {
                modifiers.contains(.shift) ? window?.selectPreviousKeyView(self) : window?.selectNextKeyView(self)
            }
        case 123 where modifiers.isEmpty: scene.moveSelection(.previous)
        case 124 where modifiers.isEmpty: scene.moveSelection(.next)
        case 126 where modifiers.isEmpty: scene.moveSelection(.up)
        case 125 where modifiers.isEmpty: scene.moveSelection(.down)
        case 36, 76 where modifiers.isEmpty:  // Return, Enter
            if let id = scene.selectedAgent { scene.onActivate?(id) } else { NSSound.beep() }
        default:
            super.keyDown(with: event)
        }
    }
}

extension SKView {
    /// 화면에 보낼 그림판(drawable)을 3장 → 2장으로 (M6(1)): 사무실 창은 한 장이 2360×1496픽셀(14MB)이라 메모리 목표(150MB)에 걸립니다.
    /// 30fps 이하로만 그리므로 2장이면 기다리지 않습니다.
    func limitDrawables() {
        if let layer = layer as? CAMetalLayer, layer.maximumDrawableCount != 2 { layer.maximumDrawableCount = 2 }
    }
}

/// 메뉴바 아이콘 (설계서 §10, M5(3)): 작은 건물 + 상태 점(초록: 작업 중, 노랑: 승인 대기, 회색: 쉬는 중).
/// 아무도 없으면 점 없이 빈 건물. 승인 대기가 있으면 옆에 그 수를 숫자로.
struct MenuBarLabel: View {
    let roster: Roster
    /// 사무실 창 열기 동작을 모델에 넘김 (미니 사무실에서 캐릭터를 눌렀을 때 씀)
    var registerOpenWindow: (OpenWindowAction) -> Void = { _ in }
    /// 설정 창 열기 동작을 모델에 넘김 (미니 오른쪽 클릭 메뉴 "설정…", M6(11))
    var registerOpenSettings: (OpenSettingsAction) -> Void = { _ in }
    /// 메뉴바가 밝은지 어두운지에 따라 건물 색을 다시 그립니다
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let mood = roster.mood
        // VoiceOver (M6(7)): 상태 점의 색 대신 "Claude Office, 승인 대기 1명, 일하는 중 2명, 쉬는 중 3명"
        let spoken = AccessibilityText.menuBar(roster)
        Image(nsImage: MenuBarIcon.image(mood: mood, dark: colorScheme == .dark, description: spoken))
            .accessibilityLabel(spoken)
            .onAppear {
                registerOpenWindow(openWindow)
                registerOpenSettings(openSettings)
            }
        if !roster.waiting.isEmpty {
            Text("\(roster.waiting.count)")
                .accessibilityHidden(true)
        }
    }
}

/// 상태 점이 있는 메뉴바 아이콘. 점 색이 보이도록 템플릿이 아닌 그림으로 만들고,
/// 건물은 그릴 때의 모양(밝은·어두운 메뉴바)에 맞춰 검정·흰색으로 칠합니다.
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    /// - Parameter description: VoiceOver가 읽을 설명 (상태별 사람 수, M6(7)). 그림은 상태·모양별로 캐시하고 설명만 바꿉니다.
    static func image(mood: Roster.Mood, dark: Bool, description: String? = nil) -> NSImage {
        let key = "\(mood.rawValue).\(dark)"
        if let cached = cache[key] {
            if let description, cached.accessibilityDescription != description { cached.accessibilityDescription = description }
            return cached
        }
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            // 실제로 그리는 곳의 모양을 먼저 보고, 모르면 SwiftUI가 알려 준 모양을 씁니다
            let appearance = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua])
            let isDark = appearance.map { $0 == .darkAqua } ?? dark
            let ink = isDark ? NSColor.white : NSColor.black
            let symbolName = mood == .idle || mood == .empty ? "building.2" : "building.2.fill"
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [ink.withAlphaComponent(mood == .empty ? 0.55 : 0.9)]))
            if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let symbolSize = symbol.size
                symbol.draw(in: NSRect(x: 0, y: (rect.height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
            }
            guard let dot = dotColor(mood) else { return true }
            let diameter: CGFloat = 7
            let dotRect = NSRect(x: rect.width - diameter - 0.5, y: 0.5, width: diameter, height: diameter)
            // 건물과 겹치는 부분이 묻히지 않게 메뉴바 색 테두리를 두릅니다
            (isDark ? NSColor.black : NSColor.white).withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.2, dy: -1.2)).fill()
            dot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description ?? accessibility(mood)
        cache[key] = image
        return image
    }

    static func dotColor(_ mood: Roster.Mood) -> NSColor? {
        switch mood {
        case .working: NSColor.systemGreen
        case .attention: NSColor.systemYellow
        case .idle: NSColor.systemGray
        case .empty: nil
        }
    }

    static func accessibility(_ mood: Roster.Mood) -> String {
        switch mood {
        case .working: "Claude Office · 작업 중"
        case .attention: "Claude Office · 승인 대기"
        case .idle: "Claude Office · 쉬는 중"
        case .empty: "Claude Office"
        }
    }
}
