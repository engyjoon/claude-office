import OfficeCore
import SpriteKit
import SwiftUI

@main
struct ClaudeOfficeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(roster: model.roster)
        }
        .menuBarExtraStyle(.window)

        Window(OfficeWindowView.title, id: WindowID.office) {
            OfficeWindowView(model: model)
        }
        .defaultSize(width: OfficeWindowView.defaultWidth, height: 700)

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

/// 사무실 창 (M3). 왼쪽은 사무실, 오른쪽은 직원 현황 패널. 미니 사무실 패널은 M5에서 만듭니다.
struct OfficeWindowView: View {
    let model: AppModel
    @AppStorage("office.showStaffPanel") private var showStaffPanel = true
    @State private var escapeMonitor: Any?
    /// 창 기본 폭을 넓힌 뒤 한 번만, 예전 크기로 기억된 창을 넓혀 줍니다 (이후에는 사용자가 정한 크기를 따름)
    @AppStorage("office.widenedTo1400") private var widened = false

    var body: some View {
        HStack(spacing: 0) {
            SpriteView(scene: model.officeScene, preferredFramesPerSecond: 30)
                .frame(minWidth: 480, minHeight: 320)
                .background(Color(red: 0.945, green: 0.902, blue: 0.839))
                .overlay(alignment: .topTrailing) {
                    // 캐릭터를 클릭하면 누구인지 보여줍니다. 빈 곳 클릭·✕·Esc로 닫습니다.
                    if let id = model.selectedAgent, let row = model.roster.row(for: id), let team = model.roster.team(of: id) {
                        AgentCard(row: row, team: team, privacy: model.privacy) { model.select(nil) }
                            .padding(12)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    }
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
                Button {
                    showStaffPanel.toggle()
                } label: {
                    Label("직원 현황", systemImage: "sidebar.right")
                }
                .help(showStaffPanel ? "직원 현황 숨기기" : "직원 현황 보기")
            }
        }
        // SpriteKit 뷰가 키 입력을 먼저 받아서 onExitCommand로는 Esc가 오지 않습니다. 창 단위로 가로챕니다.
        .onAppear {
            widenOnceIfNeeded()
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
    static let defaultWidth: CGFloat = 1400

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

/// 메뉴바 아이콘: 아무도 없으면 빈 건물, 일하면 채운 건물, 승인 대기가 있으면 손 든 아이콘과 숫자
struct MenuBarLabel: View {
    let roster: Roster

    var body: some View {
        switch roster.mood {
        case .attention:
            HStack(spacing: 2) {
                Image(systemName: "hand.raised.fill")
                Text("\(roster.waiting.count)")
            }
        case .working:
            Image(systemName: "building.2.fill")
        case .idle, .empty:
            Image(systemName: "building.2")
        }
    }
}
