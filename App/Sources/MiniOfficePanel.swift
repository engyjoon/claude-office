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
    /// 마우스를 올리면 투명도와 상관없이 100% (M6(11))
    var hoverOpaque: Bool

    static let enabledKey = "mini.enabled"
    static let autoSwitchKey = "mini.autoSwitch"
    static let opacityKey = "mini.opacity"
    static let hoverOpaqueKey = "mini.hoverOpaque"
    /// 오른쪽 클릭 메뉴의 투명도 단계 (진한 것부터, 설정 슬라이더 범위와 같음)
    static let opacitySteps: [Double] = [1, 0.9, 0.8, 0.7, 0.6, 0.5]

    init(enabled: Bool = true, autoSwitch: Bool = true, opacity: Double = 1, hoverOpaque: Bool = true) {
        self.enabled = enabled
        self.autoSwitch = autoSwitch
        self.opacity = opacity
        self.hoverOpaque = hoverOpaque
    }

    init(defaults: UserDefaults) {
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        autoSwitch = defaults.object(forKey: Self.autoSwitchKey) as? Bool ?? true
        opacity = min(1, max(0.5, defaults.object(forKey: Self.opacityKey) as? Double ?? 1))
        hoverOpaque = defaults.object(forKey: Self.hoverOpaqueKey) as? Bool ?? true
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(autoSwitch, forKey: Self.autoSwitchKey)
        defaults.set(opacity, forKey: Self.opacityKey)
        defaults.set(hoverOpaque, forKey: Self.hoverOpaqueKey)
    }
}

/// 오른쪽 클릭 메뉴 "위치"의 네 구석 (M6(11)): 보이는 영역(`visibleFrame`) 구석에 여백 없이.
/// 가장자리 붙이기(M6(10))가 놓는 자리와 같아서, 고른 뒤 0.3초 붙이기가 다시 옮기지 않습니다.
enum MiniCorner: CaseIterable {
    case bottomRight, bottomLeft, topRight, topLeft

    var title: String {
        switch self {
        case .bottomRight: "오른쪽 아래"
        case .bottomLeft: "왼쪽 아래"
        case .topRight: "오른쪽 위"
        case .topLeft: "왼쪽 위"
        }
    }

    func frame(size: NSSize, in visible: NSRect) -> NSRect {
        let right = self == .bottomRight || self == .topRight
        let top = self == .topRight || self == .topLeft
        return NSRect(
            x: right ? visible.maxX - size.width : visible.minX, y: top ? visible.maxY - size.height : visible.minY,
            width: size.width, height: size.height)
    }

    /// 지금 프레임이 맞는 구석 (끌어서 옮긴 자리면 nil, 메뉴 체크 표시용)
    static func matching(_ frame: NSRect, in visible: NSRect) -> MiniCorner? {
        allCases.first { corner in
            let target = corner.frame(size: frame.size, in: visible)
            return abs(target.minX - frame.minX) <= 0.5 && abs(target.minY - frame.minY) <= 0.5
        }
    }
}

/// 미니 사무실 패널 (M5(4) v2): 화면 구석에 떠 있는 작은 창.
///
/// - 포커스를 빼앗지 않고(nonactivating), 모든 Space와 전체 화면 앱 위에도 보입니다.
/// - 위 20pt는 머리줄(SwiftUI, 상태 문구·다른 메인 칩), 아래는 메인 + 서브 2명 띠 사무실(SpriteKit, 배율 1). 크기는 390×200 고정입니다.
/// - 제목줄 없는 패널입니다. 어디든 누르면 미니를 숨기고 사무실 창을 열고(캐릭터를 눌렀으면 그 사람을 고름), 끌면 옮깁니다. 오른쪽 위 ✕는 끄기.
/// - 오른쪽 클릭(Ctrl+클릭, VoiceOver 메뉴 보기)은 메뉴 (M6(11)): 사무실 창 열기 · 위치 · 투명도 · 설정 · 끄기 · 종료.
///   직원 위에서 열면 맨 위에 그 직원 이름·상태와 "사무실 창에서 이 직원 보기", "터미널로/앱으로 가기"를 더합니다.
/// - 투명도를 내려 두어도 마우스를 올리면 100% (설정 "마우스를 올리면 진하게", 기본 켬).
/// - 기본 위치는 화면 오른쪽 아래 구석(여백 없이, M6(10)). 디스플레이마다 마지막 위치를 기억하고, 가장자리 40pt 안에 놓으면 끝에 딱 붙입니다.
/// - 기준은 `visibleFrame`이라 위는 메뉴바 아래, 아래는 Dock 위(자동 숨김이면 화면 끝)에 붙습니다. 둥근 모서리는 그대로입니다.
@MainActor
final class MiniOfficePanelController: NSObject, NSWindowDelegate {
    static let title = "Claude Office 미니 사무실"
    /// 가장자리와 패널 사이 여백 (M6(10): 16 → 0, 끝까지 붙음)
    static let margin: CGFloat = 0
    static let snapDistance: CGFloat = 40

    private weak var model: AppModel?
    private var panel: NSPanel?
    private var settleWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    /// 프로그램이 창을 옮기는 중 (저장·붙이기를 다시 부르지 않음)
    private var placing = false
    /// 마우스가 패널 위에 있음 / 오른쪽 클릭 메뉴가 열려 있음 (둘 중 하나면 진하게)
    private var hovering = false
    private var menuOpen = false

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
        if !panel.isVisible {
            place(panel, frame: initialFrame())
            // 예전(여백 16pt) 저장 자리도 가장자리 40pt 안이면 바로 끝에 붙입니다
            snap()
            save()
        }
        hovering = panel.frame.contains(NSEvent.mouseLocation)
        refreshAlpha(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// 투명도: 설정값, 다만 "마우스를 올리면 진하게"가 켜져 있고 마우스가 위에 있거나 메뉴가 열려 있으면 100%
    func refreshAlpha(animated: Bool = false) {
        guard let panel else { return }
        let settings = model?.miniSettings ?? MiniOfficeSettings()
        let target = CGFloat(settings.hoverOpaque && (hovering || menuOpen) ? 1 : settings.opacity)
        guard panel.alphaValue != target else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = target
            }
        } else {
            panel.alphaValue = target
        }
    }

    private func setHovering(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        refreshAlpha(animated: true)
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
        // 제목줄 없는 패널: 투명 제목줄이 머리줄을 덮어 버튼이 눌리지 않고 머리줄이 아래로 밀리던 문제(v2 확인)를 없앱니다
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.title = Self.title
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.delegate = self
        if let model {
            let container = Self.content(model: model, size: size)
            container.onContextMenu = { [weak self, weak container] event in
                guard let self, let container else { return }
                self.popUpMenu(agent: nil, event: event, in: container)
            }
            container.onShowMenu = { [weak self, weak container] in
                guard let self, let container else { return false }
                return self.popUpMenu(agent: nil, at: NSPoint(x: container.bounds.midX, y: container.bounds.midY), in: container)
            }
            container.onHover = { [weak self] on in self?.setHovering(on) }
            panel.contentView = container
        }
        model?.miniScene.onWindowDragged = { [weak self] in self?.settle(after: 0) }
        model?.miniScene.onContextMenu = { [weak self] agent, event in
            guard let self, let view = self.model?.miniScene.view else { return }
            self.popUpMenu(agent: agent, event: event, in: view)
        }
        model?.miniScene.onAccessibilityMenu = { [weak self] agent in
            guard let self, let scene = self.model?.miniScene, let view = scene.view, let window = view.window else { return false }
            // 그 직원 자리(화면 좌표 → 뷰 좌표)의 왼쪽 위에 엽니다
            let frame = scene.accessibilityScreenFrame(of: agent)
            let local = view.convert(window.convertFromScreen(frame), from: nil)
            return self.popUpMenu(agent: agent, at: NSPoint(x: local.midX, y: local.maxY), in: view)
        }
        return panel
    }

    private static func content(model: AppModel, size: NSSize) -> MiniContainerView {
        let header = CGFloat(MiniOffice.headerHeight)
        let container = MiniContainerView(frame: NSRect(origin: .zero, size: size))
        container.onClick = { [weak model] in model?.openOfficeFromMini(nil) }
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("미니 사무실")
        container.setAccessibilityHelp("누르면 사무실 창이 열려요. 직원을 누르면 그 직원을 골라 열어요. 오른쪽 클릭하면 위치·투명도 메뉴가 나와요.")
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor(white: 0, alpha: 0.25).cgColor
        let sprite = FirstMouseSKView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - header))
        sprite.autoresizingMask = [.width, .height]
        sprite.preferredFramesPerSecond = 30
        sprite.limitDrawables()
        sprite.shouldCullNonVisibleNodes = false
        sprite.allowsTransparency = false
        sprite.presentScene(model.miniScene)
        // 머리줄은 보여 주기만 하고 누르기는 아래 컨테이너가 받습니다 (어디든 누르면 사무실 창, 끌면 이동)
        let top = PassThroughHostingView(rootView: MiniHeaderView(model: model))
        top.frame = NSRect(x: 0, y: size.height - header, width: size.width, height: header)
        top.autoresizingMask = [.width, .minYMargin]
        top.safeAreaRegions = []
        let close = FirstMouseButton(frame: NSRect(x: size.width - header, y: size.height - header, width: header, height: header))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "미니 사무실 끄기")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        close.contentTintColor = NSColor(red: 0.23, green: 0.2, blue: 0.28, alpha: 0.8)
        close.isBordered = false
        close.toolTip = "미니 사무실 끄기 (사무실 창의 \"미니 사무실로\" 버튼이나 메뉴바에서 다시 켜요)"
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.onPress = { [weak model] in model?.setMiniEnabled(false) }
        container.addSubview(sprite)
        container.addSubview(top)
        container.addSubview(close)
        return container
    }

    // MARK: - 오른쪽 클릭 메뉴 (M6(11))

    /// 오른쪽 클릭·Ctrl+클릭: 누른 자리에서 엽니다 (닫힐 때까지 기다림)
    private func popUpMenu(agent: AgentID?, event: NSEvent, in view: NSView) {
        let menu = makeMenu(agent: agent)
        withMenuOpen { NSMenu.popUpContextMenu(menu, with: event, for: view) }
    }

    /// VoiceOver 메뉴 보기(AXShowMenu): 정한 자리에서 엽니다
    @discardableResult
    private func popUpMenu(agent: AgentID?, at point: NSPoint, in view: NSView) -> Bool {
        let menu = makeMenu(agent: agent)
        // 그 자리(메뉴 왼쪽 위)에서 열면 화면 구석의 미니에서는 아래로 넘쳐 스크롤 메뉴가 되므로, 보이는 영역 안으로 당깁니다
        var location = point
        if let window = view.window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let size = menu.size
            var screen = window.convertPoint(toScreen: view.convert(point, to: nil))
            screen.x = min(max(screen.x, visible.minX), visible.maxX - size.width)
            screen.y = max(min(screen.y, visible.maxY), visible.minY + size.height)
            location = view.convert(window.convertPoint(fromScreen: screen), from: nil)
        }
        var shown = false
        withMenuOpen { shown = menu.popUp(positioning: nil, at: location, in: view) }
        return shown
    }

    /// 메뉴가 열린 동안은 진하게. 닫힌 뒤에는 마우스가 실제로 위에 있는지 다시 봅니다.
    private func withMenuOpen(_ body: () -> Void) {
        menuOpen = true
        refreshAlpha(animated: true)
        body()
        menuOpen = false
        hovering = panel.map { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) } ?? false
        refreshAlpha(animated: true)
    }

    func makeMenu(agent: AgentID?) -> NSMenu {
        let menu = NSMenu(title: "미니 사무실")
        guard let model else { return menu }
        if let agent, let row = model.roster.row(for: agent) {
            // 회색 제목 줄: "서브 · 생각 중" (동작 없는 항목은 자동으로 흐리게)
            let status = row.status == .waitingForPermission ? model.waitLabel(of: agent) : row.status.label
            let title = NSMenuItem(title: "\(row.title.label) · \(status)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(BlockMenuItem("사무실 창에서 이 직원 보기") { [weak model] in model?.openOfficeFromMini(agent) })
            if let focus = row.focusLabel {
                menu.addItem(BlockMenuItem("\(focus) 가기") { [weak model] in model?.focusFromMini(agent) })
            } else {
                let none = NSMenuItem(title: "터미널로 가기", action: nil, keyEquivalent: "")
                none.toolTip = "이 세션의 앱이나 터미널을 몰라요"
                menu.addItem(none)
            }
            menu.addItem(.separator())
        }
        menu.addItem(BlockMenuItem("사무실 창 열기", key: "o") { [weak model] in model?.openOfficeFromMini(nil) })
        menu.addItem(.separator())

        let corners = NSMenu(title: "위치")
        var current: MiniCorner?
        if let panel, let screen = panel.screen { current = MiniCorner.matching(panel.frame, in: screen.visibleFrame) }
        for corner in MiniCorner.allCases {
            corners.addItem(BlockMenuItem(corner.title, checked: corner == current) { [weak self] in self?.move(to: corner) })
        }
        menu.addItem(Self.submenu("위치", corners))

        let settings = model.miniSettings
        let opacity = NSMenu(title: "투명도")
        for step in MiniOfficeSettings.opacitySteps {
            opacity.addItem(BlockMenuItem("\(Int((step * 100).rounded()))%", checked: abs(settings.opacity - step) < 0.005) { [weak model] in
                guard let model else { return }
                var next = model.miniSettings
                next.opacity = step
                model.setMiniSettings(next)
            })
        }
        opacity.addItem(.separator())
        opacity.addItem(BlockMenuItem("마우스를 올리면 진하게", checked: settings.hoverOpaque) { [weak model] in
            guard let model else { return }
            var next = model.miniSettings
            next.hoverOpaque.toggle()
            model.setMiniSettings(next)
        })
        menu.addItem(Self.submenu("투명도", opacity))
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem("설정…", key: ",") { [weak model] in model?.openSettingsWindow() })
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem("미니 사무실 끄기") { [weak model] in model?.setMiniEnabled(false) })
        menu.addItem(BlockMenuItem("Claude Office 종료", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// 메뉴 "위치": 패널이 놓인 화면의 그 구석으로 0.25초에 옮기고(동작 줄이기면 바로) 그 화면 자리로 저장
    func move(to corner: MiniCorner) {
        guard let panel, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let target = corner.frame(size: panel.frame.size, in: visible)
        settleWork?.cancel()
        guard target != panel.frame else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            place(panel, frame: target)
            save()
            return
        }
        placing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.placing = false
                self.save()
            }
        }
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
final class FirstMouseSKView: AccessibleSKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 그리기만 하고 마우스는 받지 않는 SwiftUI 뷰 (아래 컨테이너가 받음)
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 비활성 패널에서도 첫 클릭에 눌리는 버튼
final class FirstMouseButton: NSButton {
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)는 쓰지 않습니다") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func press() { onPress?() }
}

/// 미니 패널 바탕: 누르면 `onClick`, 끌면 창을 옮깁니다 (사무실 장면은 `OfficeScene`이 같은 방식으로 처리).
/// 오른쪽 클릭·Ctrl+클릭은 `onContextMenu`, 마우스가 들어오고 나가면 `onHover` (M6(11)).
final class MiniContainerView: NSView {
    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onShowMenu: (() -> Bool)?
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let onContextMenu { return onContextMenu(event) }
        guard let window else { return }
        if !MiniWindowDrag.track(event, in: window) { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(event)
    }

    // 장면 위는 장면(`OfficeScene`)이 오른쪽 클릭을 받아 누른 직원과 함께 엽니다

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// VoiceOver 누르기 = 패널 누르기 (사무실 창 열기, M6(7))
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    /// VoiceOver 메뉴 보기 (VO+Shift+M, M6(11))
    override func accessibilityPerformShowMenu() -> Bool {
        onShowMenu?() ?? false
    }
}

/// 클로저를 부르는 메뉴 항목 (미니 오른쪽 클릭 메뉴, M6(11))
final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = key.isEmpty ? [] : .command
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:)는 쓰지 않습니다") }

    @objc private func run() { handler() }
}

/// 미니 패널 끌기: 마우스를 놓을 때까지 창을 따라 옮기고, 3pt 넘게 움직였으면 true (아니면 클릭)
enum MiniWindowDrag {
    @MainActor
    static func track(_ event: NSEvent, in window: NSWindow) -> Bool {
        let start = NSEvent.mouseLocation
        let origin = window.frame.origin
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let now = NSEvent.mouseLocation
            let (dx, dy) = (now.x - start.x, now.y - start.y)
            if !moved, hypot(dx, dy) > 3 { moved = true }
            if moved { window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
            if next.type == .leftMouseUp { break }
        }
        return moved
    }
}

/// 미니 사무실 머리줄 (20pt, v2): 지금 보여 주는 메인의 상태와 다른 메인 칩. 보여 주기만 합니다(누르기는 패널 전체가 받음).
///
/// - 답변 필요: 노랑, "서브3 승인 대기 12초째" (질문이면 "질문 답 대기", 계획이면 "계획 승인 대기")
/// - 완료: 초록, "✓ 응답 완료 · 2분 전"
/// - 그 밖: "작업 중 · 요청 5분 전" / "쉬는 중 · 요청 1시간 전"
/// 메인·디렉토리 이름은 사무실의 명패·폴더 표지에 이미 있어 쓰지 않습니다. 오른쪽 끝은 ✕ 버튼 자리입니다.
struct MiniHeaderView: View {
    let model: AppModel
    /// 시스템 "대비 증가" (M6(7)): 칩 테두리를 잉크색으로
    @Environment(\.colorSchemeContrast) private var contrast

    private static let ink = Color(hex: 0x3A3247)
    private static let paper = Color(hex: 0xFFF8EC)
    private static let done = Color(hex: 0xCFEBD9)
    /// 밤 조명일 때 평소 머리줄 (M6(6)): 밤 사무실 벽과 어울리는 남색, 밝은 글자. 승인 대기·답변 필요·새 응답 색은 낮과 같습니다.
    private static let nightPaper = Color(hex: 0x33365A)
    private static let nightInk = Color(hex: 0xF1ECE4)
    private static let nightLine = Color(hex: 0x262842)
    private static let maxChips = 3

    var body: some View {
        let roster = model.roster
        let focus = model.miniFocus
        let current = roster.teams.first { $0.id == focus.team }
        let waiting = (current?.rows ?? []).filter { $0.status == .waitingForPermission }.sorted { $0.since < $1.since }
        let line = Self.latest(focus: focus, rows: current?.rows ?? [], waiting: waiting)
        let others = roster.teams.filter { $0.id != current?.id }
            .sorted { Self.rank(focus.tiers[$0.id]) < Self.rank(focus.tiers[$1.id]) }
        let nightPlain = model.isNight && (line == nil || line?.kind == .normal)
        let shown = Array(others.prefix(Self.maxChips))
        let extra = max(others.count - Self.maxChips, 0)
        // 글자가 바뀌는 때만 (M6(1)): 답변 대기 "12초째"는 1초마다, "3분 전"은 1분마다
        // 미니가 숨어 있으면 멈춥니다. 칩까지 안에 두는 것은 VoiceOver 값이 화면 문구와 같은 시각을 쓰게 하려고 (M6(7b))
        TimelineView(NextChangeSchedule { [line, live = model.miniVisible] in live ? Self.nextChange(line, after: $0) : nil }) { context in
            let headline = current == nil ? "아직 출근한 직원이 없어요" : statusText(line, waitingCount: waiting.count, now: context.date)
            HStack(spacing: 5) {
                Text(headline)
                    .font(.system(size: 10.5, weight: line?.kind == .normal ? .regular : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(nightPlain ? Self.nightInk : Self.ink)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                ForEach(shown) { team in
                    chip(team, tier: focus.tiers[team.id] ?? .none)
                }
                if extra > 0 {
                    Text("+\(extra)")
                        .font(.system(size: 9.5))
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(.white))
                        .overlay(Capsule().stroke(contrast == .increased ? Self.ink : Color(hex: 0xCFC6D9)))
                }
            }
            // VoiceOver (M6(7b)): 라벨 "미니 사무실 머리줄", 값 = 화면 문구 + 다른 메인 칩("메인2, 답변 기다림")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("미니 사무실 머리줄")
            .accessibilityValue(AccessibilityText.miniHeader(
                status: headline, chips: shown.map { Self.chipLabel($0, tier: focus.tiers[$0.id] ?? .none) }, more: extra))
        }
        .foregroundStyle(Self.ink)
        .padding(.leading, 10)
        .padding(.trailing, CGFloat(MiniOffice.headerHeight))  // ✕ 자리
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            line?.kind == .answer ? Palette.attention : line?.kind == .reply ? Palette.reply : line?.kind == .completed ? Self.done
                : nightPlain ? Self.nightPaper : Self.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(model.isNight ? Self.nightLine : Color(hex: 0xD8CDBE)).frame(height: 1) }
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

    /// 다른 메인: "?2"(답변 필요, 노랑), "✉3"(확인 안 한 응답, 초록), "1"
    private func chip(_ team: RosterTeam, tier: MiniFocus.Tier) -> some View {
        let number = team.mainName.replacingOccurrences(of: "메인", with: "")
        let (icon, fill, stroke): (String, Color, UInt32) = switch tier {
        case .answer: ("?", Palette.attention, 0xE2B93B)
        case .completed: ("✉", Self.done, 0x5DBB7A)
        default: ("", .white, 0xCFC6D9)
        }
        return HStack(spacing: 3) {
            Circle().fill(Palette.team(team.colorIndex)).frame(width: 6, height: 6)
            Text(icon + (number.isEmpty ? "메인" : number))
                .font(.system(size: 9.5, weight: tier == .requested || tier == .none ? .regular : .bold))
        }
        .padding(.horizontal, 5)
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(contrast == .increased ? Self.ink : Color(hex: stroke), lineWidth: contrast == .increased ? 1.2 : 1))
        .fixedSize()
    }

    /// 칩을 말로: "메인2, 답변 기다림" / "메인3, 새 응답" / "메인1"
    private static func chipLabel(_ team: RosterTeam, tier: MiniFocus.Tier) -> String {
        let spoken: String? = switch tier {
        case .answer: "답변 기다림"
        case .completed: "새 응답"
        default: nil
        }
        return AccessibilityText.miniChip(main: team.mainName, tier: spoken)
    }

    /// 머리줄에 보여 줄 한 사람: 답변을 기다리는 사람이 있으면 가장 오래 기다린 사람, 아니면 가장 마지막으로 상태가 바뀐 사람
    struct Line {
        /// answer = 승인·질문 답 대기("!"), reply = 응답을 끝내고 답을 기다림("?"), completed = 확인 안 한 응답(✉) (M6(4))
        enum Kind { case answer, reply, completed, normal }
        var row: RosterRow
        var kind: Kind
    }

    static func latest(focus: MiniFocus, rows: [RosterRow], waiting: [RosterRow]) -> Line? {
        if let first = waiting.first { return Line(row: first, kind: .answer) }
        if let asker = rows.filter({ $0.status == .awaitingReply }).min(by: { ($0.since, $0.id) < ($1.since, $1.id) }) {
            return Line(row: asker, kind: .reply)
        }
        guard let row = rows.max(by: { ($0.since, $1.id) < ($1.since, $0.id) }) else { return nil }
        return Line(row: row, kind: row.status == .unread ? .completed : .normal)
    }

    /// "서브: 요청 받음 · 방금", "메인: 응답 완료 · 1분 전", "서브3: 승인 대기 12초째", "메인: 쉬는 중 · 3분 전"
    private func statusText(_ line: Line?, waitingCount: Int, now: Date) -> String {
        guard let line else { return "" }
        let row = line.row
        let name = row.title.label
        switch line.kind {
        case .answer:
            let elapsed = StatusLine.elapsed(now.timeIntervalSince(row.since)).map { " \($0)" } ?? ""
            let more = waitingCount > 1 ? " (외 \(waitingCount - 1)명)" : ""
            return "\(name): \(model.waitLabel(of: row.id))\(elapsed)\(more)"
        case .reply:
            return "\(name): 답변 필요 · \(Self.ago(row.since, now: now))"
        case .completed:
            return "\(name): 새 응답 · \(Self.ago(row.since, now: now))"
        case .normal:
            let prompted = row.status == .thinking && model.promptedAt(row).map { abs($0.timeIntervalSince(row.since)) < 1 } == true
            return "\(name): \(prompted ? "요청 받음" : row.status.label) · \(Self.ago(row.since, now: now))"
        }
    }

    /// 머리줄 글자가 다음에 바뀌는 때: 답변 대기는 "N초째"라 1초마다, 나머지는 `ago`가 1분 단위라 다음 분 경계
    static func nextChange(_ line: Line?, after now: Date) -> Date? {
        guard let line else { return nil }
        if line.kind == .answer {
            let elapsed = max(now.timeIntervalSince(line.row.since), 0)
            let step: TimeInterval = elapsed < 60 ? 1 : 60
            return line.row.since.addingTimeInterval(((elapsed / step).rounded(.down) + 1) * step)
        }
        let elapsed = max(now.timeIntervalSince(line.row.since), 0)
        let step: TimeInterval = elapsed < 3600 ? 60 : 3600
        return line.row.since.addingTimeInterval(((elapsed / step).rounded(.down) + 1) * step)
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
