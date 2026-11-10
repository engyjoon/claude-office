import AppKit

/// 메뉴바 앱(LSUIElement)의 창을 다른 앱 창 위로 가져옵니다 (M5(8) 설정 창, M6(17) 사무실 창).
///
/// - 미니 사무실은 앱을 활성화하지 않는 패널(`.nonactivatingPanel`)이라 눌러도 앱이 앞으로 오지 않습니다.
///   macOS 14의 협력 활성화 `NSApp.activate()`는 지금 앞에 있는 앱이 양보하지 않으면 거절될 수 있어서,
///   그때 연 창은 다른 앱 창 뒤에 깔립니다. 그래서 `activate(ignoringOtherApps:)`(14에서 폐기 예정이지만 동작함)로 활성화합니다.
/// - SwiftUI `openWindow`는 창을 비동기로 만들거나 앞으로 가져오므로, 창이 생길 때까지 몇 번(0~0.6초) 다시 올립니다.
/// - 최소화돼 있으면 Dock에서 꺼내고, 다른 Space에 있으면 지금 Space로 데려옵니다(그 Space로 화면이 넘어가지 않게).
@MainActor
enum WindowFront {
    static let retryDelays: [Double] = [0.0, 0.1, 0.3, 0.6]

    /// 앱을 활성화하고 `open`(창 열기)을 부른 뒤, `find`로 찾은 창을 맨 앞으로 몇 번 올립니다.
    static func bring(open: (() -> Void)? = nil, find: @escaping @MainActor () -> NSWindow?) {
        activateApp()
        open?()
        for delay in retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard let window = find() else { return }
                    raise(window)
                }
            }
        }
    }

    /// 창 하나를 맨 앞의 키 창으로
    static func raise(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isOnActiveSpace, !window.collectionBehavior.contains(.canJoinAllSpaces) {
            // 잠깐 "지금 Space로 옮기기"를 켜고 앞으로 올린 뒤 되돌립니다
            let behavior = window.collectionBehavior
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            window.collectionBehavior = behavior
        }
        if !NSApp.isActive { activateApp() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 사무실 창 (`Window(OfficeWindowView.title, id: WindowID.office)`)
enum OfficeWindow {
    /// 떠 있든 최소화돼 있든 닫힌 뒤 남아 있든, 사무실 창 객체
    @MainActor static var window: NSWindow? {
        NSApp.windows.first { $0.title == OfficeWindowView.title }
    }
}

/// 설정 창을 앞으로 가져옵니다. 메뉴바 앱은 활성화가 끝나기 전에 설정 창이 열리면
/// 다른 앱 창 뒤에 깔리기 쉬워서, 활성화한 뒤 창이 생길 때까지 몇 번 앞으로 올립니다 (M5(8)).
enum SettingsWindow {
    @MainActor static func bringToFront() {
        WindowFront.bring { window }
    }

    /// SwiftUI `Settings` 장면의 창
    @MainActor static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" && $0.isVisible }
    }
}
