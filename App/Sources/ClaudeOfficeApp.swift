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

        Window("Claude Office 사무실", id: WindowID.office) {
            OfficeWindowView(model: model)
        }
        .defaultSize(width: 960, height: 640)

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

/// 사무실 창 (M3). 미니 사무실 패널은 M5에서 만듭니다.
struct OfficeWindowView: View {
    let model: AppModel

    var body: some View {
        SpriteView(scene: model.officeScene, preferredFramesPerSecond: 30)
            .frame(minWidth: 480, minHeight: 320)
            .background(Color(red: 0.945, green: 0.902, blue: 0.839))
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
