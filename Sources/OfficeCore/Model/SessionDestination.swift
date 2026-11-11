import Foundation

/// 세션으로 "이동"할 곳 (설계서 §10.3). 이동할 수 있는지·버튼 문구·도움말·앞으로 가져올 앱을 한 곳에서 정합니다.
///
/// - 데스크톱 앱 세션(`hostSession`이 있음)이면 Claude 데스크톱 앱의 그 세션으로.
/// - 터미널 CLI 세션이면 `TERM_PROGRAM`으로 아는 터미널(에디터)을 앞으로. 모르는 터미널(tmux·zed 등)이면 `nil`이라
///   버튼·도움말을 보여 주지 않습니다.
/// - VS Code 계열(VS Code·Insiders·Cursor)은 모두 `TERM_PROGRAM=vscode`이고 훅은 이 값만 보내므로 구별할 수 없습니다.
///   앱은 후보 중 실행 중인 첫 앱을 고릅니다(`bundleIDs` 순서).
public struct SessionDestination: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Claude 데스크톱 앱의 세션 (`local_…`)
        case desktopApp(session: String)
        /// `TERM_PROGRAM` 값
        case terminal(term: String)
    }

    public let kind: Kind
    /// 앞으로 가져올 앱 후보 (앞의 것부터, 실행 중인 앱이 먼저)
    public let bundleIDs: [String]
    /// 로그·도움말에 쓰는 이름 ("Claude 데스크톱 앱", "iTerm2")
    public let displayName: String

    public static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// 아는 터미널(에디터)의 `TERM_PROGRAM` → 번들 id 후보
    public static let terminalBundleIDs: [String: [String]] = [
        "iTerm.app": ["com.googlecode.iterm2"],
        "Apple_Terminal": ["com.apple.Terminal"],
        // VS Code 계열은 모두 TERM_PROGRAM이 vscode입니다 (VS Code, Insiders, Cursor)
        "vscode": ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"],
        "ghostty": ["com.mitchellh.ghostty"],
        "WarpTerminal": ["dev.warp.Warp-Stable"],
        "WezTerm": ["com.github.wez.wezterm"],
        "Hyper": ["co.zeit.hyper"],
    ]

    /// 갈 곳. 데스크톱 앱 세션이 먼저이고, 모르는 터미널이면 nil.
    public static func resolve(hostSession: String?, term: String?) -> SessionDestination? {
        if let hostSession, !hostSession.isEmpty {
            return SessionDestination(kind: .desktopApp(session: hostSession), bundleIDs: [desktopBundleID],
                                      displayName: "Claude 데스크톱 앱")
        }
        guard let term, let ids = terminalBundleIDs[term] else { return nil }
        return SessionDestination(kind: .terminal(term: term), bundleIDs: ids, displayName: displayName(term: term) ?? term)
    }

    /// 터미널 이름 (보여 주기용). 모르는 값은 그대로 ("tmux"), 없으면 nil.
    public static func displayName(term: String?) -> String? {
        switch term {
        case "iTerm.app": "iTerm2"
        case "Apple_Terminal": "터미널"
        case "vscode": "VS Code"
        case "ghostty": "Ghostty"
        case "WarpTerminal": "Warp"
        case .some(let other): other.isEmpty ? nil : other
        case .none: nil
        }
    }

    public var isDesktopApp: Bool {
        if case .desktopApp = kind { return true }
        return false
    }

    /// 버튼 문구 ("앱으로", "터미널로")
    public var label: String { isDesktopApp ? "앱으로" : "터미널로" }

    /// 버튼에 마우스를 올렸을 때
    public var buttonHelp: String {
        isDesktopApp ? "Claude 데스크톱 앱에서 이 세션을 열어요" : "\(displayName) 창을 앞으로 가져와요"
    }

    /// 줄·캐릭터 더블클릭 도움말
    public var doubleClickHelp: String { "더블클릭하면 \(label) 이동" }
}

extension RosterRow {
    /// 이 사람이 속한 세션으로 갈 곳 (서브에이전트도 자기 세션 기준). 모르면 nil.
    public var destination: SessionDestination? { SessionDestination.resolve(hostSession: hostSession, term: term) }

    /// 앞으로 가져올 곳이 있는지 (데스크톱 앱 세션이거나 아는 터미널)
    public var canFocus: Bool { destination != nil }

    /// 이동 버튼·더블클릭 도움말 문구 (M5(7)): "앱으로"·"터미널로", 갈 곳을 모르면 nil
    public var focusLabel: String? { destination?.label }
}
