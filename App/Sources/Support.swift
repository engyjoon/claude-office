import AppKit
import OfficeCore
import SwiftUI

/// 미리보기(docs/preview)와 같은 파스텔 팔레트 (설계서 §9.2)
enum Palette {
    static let tops: [UInt32] = [0x9FD8C7, 0xF6B9A0, 0xC7BCEB, 0xF7DE8B, 0xA9D3F0, 0xF4A3B4]
    static let skins: [UInt32] = [0xFBDDC8, 0xF3C6A5, 0xD9A47F, 0xB07A5C]
    static let teams: [UInt32] = [0x9FD8C7, 0xF6B9A0, 0xC7BCEB, 0xF7DE8B]
    /// 승인 대기 형광펜 (현황 줄·타임라인 글자 바탕). 글자는 언제나 `ink`
    static let attention = Color(hex: 0xF7DE8B)
    /// 승인 대기 칩 바탕: 형광펜보다 진한 노랑 (M5(9) 화면 확인: 어두운 모드에서 흐린 노랑에 흰 글자가 안 보임)
    static let attentionStrong = Color(hex: 0xF5C443)
    /// 밝은 바탕(파스텔 칩·형광펜) 위 글자색. 어두운 모드에서도 흰 글자가 되지 않게 고정합니다.
    static let ink = Color(hex: 0x2B2418)

    static func top(_ index: Int) -> Color { Color(hex: tops[abs(index) % tops.count]) }
    static func skin(_ index: Int) -> Color { Color(hex: skins[abs(index) % skins.count]) }
    static func team(_ index: Int) -> Color { Color(hex: teams[abs(index) % teams.count]) }

    /// 상태 칩 바탕. 밝은 모드는 흰 바탕에 비치는 연한 파스텔, 어두운 모드는 비치지 않는 파스텔(글자는 `chipText`의 진한 잉크).
    /// 답변 필요 (응답을 끝내고 내 답을 기다림, M6(4)): 배지의 파랑을 옅게
    static let reply = Color(hex: 0xC9DAFB)

    static func chip(_ tone: RosterStatus.Tone, dark: Bool = false) -> Color {
        switch tone {
        case .working: Color(hex: 0x9FD8C7).opacity(dark ? 1 : 0.55)
        case .reading: Color(hex: 0xC7BCEB).opacity(dark ? 1 : 0.6)
        case .running: Color(hex: 0xA9D3F0).opacity(dark ? 1 : 0.6)
        case .attention: attentionStrong
        case .reply: reply
        case .calm: Color.secondary.opacity(0.15)
        }
    }

    /// 상태 칩 글자색: 색이 있는 칩은 진한 잉크(어두운 모드에서도), 쉬는 칩은 기본 글자색
    static func chipText(_ tone: RosterStatus.Tone) -> Color {
        tone == .calm ? .primary : ink
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// TERM_PROGRAM 값으로 해당 터미널(또는 에디터)을 앞으로 가져옵니다 (설계서 §10).
/// 특정 탭까지 찾아가는 기능은 이후 단계에서 iTerm2부터 지원합니다.
enum TerminalFocuser {
    static let bundleIDs: [String: [String]] = [
        "iTerm.app": ["com.googlecode.iterm2"],
        "Apple_Terminal": ["com.apple.Terminal"],
        // VS Code 계열은 모두 TERM_PROGRAM이 vscode입니다
        "vscode": ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"],
        "ghostty": ["com.mitchellh.ghostty"],
        "WarpTerminal": ["dev.warp.Warp-Stable"],
        "WezTerm": ["com.github.wez.wezterm"],
        "Hyper": ["co.zeit.hyper"],
    ]

    static func displayName(for term: String?) -> String? {
        switch term {
        case "iTerm.app": "iTerm2"
        case "Apple_Terminal": "터미널"
        case "vscode": "VS Code"
        case "ghostty": "Ghostty"
        case "WarpTerminal": "Warp"
        case .some(let other): other
        case .none: nil
        }
    }

    @discardableResult
    static func focus(term: String?) -> Bool {
        guard let term, let candidates = bundleIDs[term] else { return false }
        for identifier in candidates {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                return running.activate()
            }
        }
        for identifier in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
        }
        return false
    }
}

extension RosterRow {
    /// 이동 버튼·더블클릭 도움말 문구 (M5(7)): 데스크톱 앱 세션이면 "앱으로", 아는 터미널(에디터)이면 "터미널로", 갈 곳을 모르면 nil
    var focusLabel: String? {
        if hostSession != nil { return "앱으로" }
        if let term, TerminalFocuser.bundleIDs[term] != nil { return "터미널로" }
        return nil
    }
}
