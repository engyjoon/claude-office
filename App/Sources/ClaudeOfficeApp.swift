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
            MenuBarLabel(roster: model.roster) { model.registerOpenWindow($0) }
        }
        .menuBarExtraStyle(.window)

        Window(OfficeWindowView.title, id: WindowID.office) {
            OfficeWindowView(model: model)
        }
        .defaultSize(width: OfficeWindowView.defaultWidth, height: OfficeWindowView.defaultHeight)

        Window("Claude Office 이벤트 로그", id: WindowID.eventLog) {
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

/// 사무실 창 (M3). 왼쪽은 사무실과 그 아래 실시간 현황 줄, 오른쪽은 디렉토리·세션 패널.
struct OfficeWindowView: View {
    let model: AppModel
    @AppStorage("office.showStaffPanel") private var showStaffPanel = true
    @State private var escapeMonitor: Any?
    /// 창 기본 폭을 넓힌 뒤 한 번만, 예전 크기로 기억된 창을 넓혀 줍니다 (이후에는 사용자가 정한 크기를 따름)
    @AppStorage("office.widenedTo1440") private var widened = false
    /// 현황 줄을 넣은 뒤 한 번만, 예전 높이로 기억된 창을 줄 높이만큼 늘려 줍니다 (사무실 영역 높이 유지)
    @AppStorage("office.tallerForStatusLine") private var heightened = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SpriteView(scene: model.officeScene, preferredFramesPerSecond: 30)
                    // 3행이 언제나 다 보이도록 사무실 영역이 3행 높이보다 낮아지지 않게 합니다
                    .frame(minWidth: 480, minHeight: OfficeLayout.minHeight + OfficeLayout.padding * 2)
                    .background(Color(red: 0.945, green: 0.902, blue: 0.839))
                    .overlay(alignment: .topTrailing) {
                        // 캐릭터를 클릭하면 누구인지 보여줍니다. 빈 곳 클릭·✕·Esc로 닫습니다.
                        if let id = model.selectedAgent, let row = model.roster.row(for: id), let team = model.roster.team(of: id) {
                            AgentCard(row: row, team: team, privacy: model.privacy) { model.select(nil) }
                                .padding(12)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                        }
                    }
                // 사무실 바로 아래 한 줄 (사무실 영역은 이 줄을 뺀 높이: 씬 크기와 행 수 계산이 이 줄을 빼고 맞춤)
                StatusLineView(line: model.statusLine)
            }
            if showStaffPanel {
                Divider()
                StaffPanel(model: model)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.selectedAgent)
        .animation(.easeOut(duration: 0.2), value: showStaffPanel)
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
            widenOnceIfNeeded()
            heightenOnceIfNeeded()
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
    static let defaultWidth: CGFloat = 1440
    /// 사무실 영역 기본 높이(`OfficeLayout.defaultHeight` + 둘레 여백) + 현황 줄 + 제목 막대
    static let defaultHeight: CGFloat = 800 + StatusLineView.height

    private func heightenOnceIfNeeded() {
        guard !heightened else { return }
        heightened = true
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == Self.title }),
                  window.frame.height < Self.defaultHeight else { return }
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            var frame = window.frame
            let grow = min(StatusLineView.height, max(0, visible.height - frame.height))
            frame.size.height += grow
            frame.origin.y = max(visible.minY, frame.origin.y - grow)  // 위쪽 모서리를 유지하고 아래로 늘림
            window.setFrame(frame, display: true, animate: true)
        }
    }

    private func widenOnceIfNeeded() {
        guard !widened else { return }
        widened = true
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == Self.title }),
                  window.frame.width < Self.defaultWidth else { return }
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            var frame = window.frame
            let center = frame.midX  // 가운데를 유지한 채 넓히고, 화면 밖으로 나가지 않게 합니다
            frame.size.width = min(Self.defaultWidth, visible.width)
            frame.origin.x = max(visible.minX, min(center - frame.width / 2, visible.maxX - frame.width))
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

/// 메뉴바 아이콘 (설계서 §10, M5(3)): 작은 건물 + 상태 점(초록: 작업 중, 노랑: 승인 대기, 회색: 쉬는 중).
/// 아무도 없으면 점 없이 빈 건물. 승인 대기가 있으면 옆에 그 수를 숫자로.
struct MenuBarLabel: View {
    let roster: Roster
    /// 사무실 창 열기 동작을 모델에 넘김 (미니 사무실에서 캐릭터를 눌렀을 때 씀)
    var registerOpenWindow: (OpenWindowAction) -> Void = { _ in }
    /// 메뉴바가 밝은지 어두운지에 따라 건물 색을 다시 그립니다
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let mood = roster.mood
        Image(nsImage: MenuBarIcon.image(mood: mood, dark: colorScheme == .dark))
            .onAppear { registerOpenWindow(openWindow) }
        if !roster.waiting.isEmpty {
            Text("\(roster.waiting.count)")
        }
    }
}

/// 상태 점이 있는 메뉴바 아이콘. 점 색이 보이도록 템플릿이 아닌 그림으로 만들고,
/// 건물은 그릴 때의 모양(밝은·어두운 메뉴바)에 맞춰 검정·흰색으로 칠합니다.
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(mood: Roster.Mood, dark: Bool) -> NSImage {
        let key = "\(mood.rawValue).\(dark)"
        if let cached = cache[key] { return cached }
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
        image.accessibilityDescription = accessibility(mood)
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
