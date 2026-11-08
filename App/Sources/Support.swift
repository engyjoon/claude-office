import AppKit
import OfficeCore
import SwiftUI

/// 미리보기(docs/preview)와 같은 파스텔 팔레트 (설계서 §9.2)
enum Palette {
    static let tops: [UInt32] = [0x9FD8C7, 0xF6B9A0, 0xC7BCEB, 0xF7DE8B, 0xA9D3F0, 0xF4A3B4]
    static let skins: [UInt32] = [0xFBDDC8, 0xF3C6A5, 0xD9A47F, 0xB07A5C]
    static let teams: [UInt32] = [0x9FD8C7, 0xF6B9A0, 0xC7BCEB, 0xF7DE8B]
    static let attention = Color(hex: 0xF7DE8B)

    static func top(_ index: Int) -> Color { Color(hex: tops[abs(index) % tops.count]) }
    static func skin(_ index: Int) -> Color { Color(hex: skins[abs(index) % skins.count]) }
    static func team(_ index: Int) -> Color { Color(hex: teams[abs(index) % teams.count]) }

    static func chip(_ tone: RosterStatus.Tone) -> Color {
        switch tone {
        case .working: Color(hex: 0x9FD8C7).opacity(0.55)
        case .reading: Color(hex: 0xC7BCEB).opacity(0.6)
        case .running: Color(hex: 0xA9D3F0).opacity(0.6)
        case .attention: Color(hex: 0xF7DE8B)
        case .calm: Color.secondary.opacity(0.15)
        }
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
