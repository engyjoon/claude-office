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

    /// - Parameter increased: 시스템 "대비 증가" (M6(7)). 비치는 파스텔을 꽉 채우고, 쉬는 칩 바탕을 조금 진하게.
    static func chip(_ tone: RosterStatus.Tone, dark: Bool = false, increased: Bool = false) -> Color {
        let solid = dark || increased
        switch tone {
        case .working: return Color(hex: 0x9FD8C7).opacity(solid ? 1 : 0.55)
        case .reading: return Color(hex: 0xC7BCEB).opacity(solid ? 1 : 0.6)
        case .running: return Color(hex: 0xA9D3F0).opacity(solid ? 1 : 0.6)
        case .attention: return attentionStrong
        case .reply: return reply
        case .calm: return Color.secondary.opacity(increased ? 0.28 : 0.15)
        }
    }

    /// 대비 증가 칩 테두리 (M6(7)): 색이 있는 칩은 진한 잉크, 쉬는 칩은 기본 글자색
    static func chipEdge(_ tone: RosterStatus.Tone) -> Color {
        tone == .calm ? Color.primary.opacity(0.7) : ink.opacity(0.85)
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

/// `SessionDestination`(코어가 정한 갈 곳)의 앱을 실제로 앞으로 가져옵니다 (설계서 §10.3).
///
/// - 데스크톱 앱 세션: `claude://code/continue?session=local_…` 딥링크로 그 세션 화면까지 엽니다 (M5(7b)).
///   공개 문서에 있는 경로는 아니라(앱 4.23118에서 확인) 앱이 바뀌면 다시 앱 활성화만 될 수 있습니다.
///   데스크톱 설정에서 딥링크를 꺼 두었으면 앱은 링크를 무시하지만, 링크를 열 때 앱은 앞으로 옵니다(`activates`).
/// - 터미널: 후보 중 실행 중인 앱, 없으면 설치된 첫 앱. 특정 탭까지 찾아가지는 않습니다.
/// - 앞으로 가져오기는 `NSRunningApplication.activate()` 대신 `NSWorkspace.openApplication`(activates)으로 합니다.
///   macOS 14의 협력 활성화에서 앞에 있지 않은 메뉴바 앱(미니 사무실은 앱을 활성화하지 않는 패널)의 `activate()`는 거절될 수 있습니다.
@MainActor
enum SessionFocuser {
    /// 앱이 받아들이는 세션 id 모양 (앱의 검사와 같음)
    static func sessionURL(_ session: String) -> URL? {
        guard session.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(session)")
    }

    /// 갈 곳의 앱을 엽니다. 열 앱을 찾지 못하면 바로, 열다가 실패하면 나중에 `done`에 까닭을 넘깁니다(성공하면 nil).
    static func focus(_ destination: SessionDestination, done: @escaping @MainActor (String?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let finish: @Sendable (Error?) -> Void = { error in
            let message = error.map { "\($0.localizedDescription)" }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(message) } }
        }
        guard let app = applicationURL(for: destination.bundleIDs) else {
            done("\(destination.displayName)을(를) 찾지 못했어요")
            return
        }
        if case .desktopApp(let session) = destination.kind, let url = sessionURL(session) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in finish(error) }
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in finish(error) }
        }
    }

    /// 후보 중 실행 중인 앱, 없으면 설치된 첫 앱
    private static func applicationURL(for bundleIDs: [String]) -> URL? {
        for identifier in bundleIDs {
            if let url = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.bundleURL { return url }
        }
        for identifier in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        return nil
    }
}
