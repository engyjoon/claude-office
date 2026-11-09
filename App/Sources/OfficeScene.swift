import AppKit
import OfficeCore
import OfficeStage
import SpriteKit

/// 무대 상태를 담아 두는 상자. AppModel이 매 프레임 갱신하고 씬이 읽습니다 (둘 다 메인 스레드).
final class StageStore {
    /// 화면에 보일 사람만 고르는 층과 그 무대 (M5(1))
    var floor = OfficeFloor()
    var stage: Stage { floor.stage }
    /// 말풍선·상태 칩에 보여줄 내용 수준 (설정의 표시 수준)
    var privacy: PrivacyLevel = .detailed
    /// 사무실 조명 (M6(6)). 바꿀 때는 씬의 `setLighting`을 거쳐 크로스페이드합니다.
    var lighting: Lighting = .day
    /// 시스템 "대비 증가" (M6(7)): 상태 칩·배지·명패 테두리를 진하게
    var highContrast = false
}

/// SpriteKit 사무실 화면 (설계서 §8).
///
/// 무대(Stage)를 그대로 옮겨 그리기만 합니다. 판단과 타이밍은 모두 OfficeCore·OfficeStage에 있고,
/// 그림 데이터는 SVG 스냅숏과 같은 OfficeArt·CharacterArt를 씁니다.
/// 좌표 변환: 그림 데이터는 y가 아래로 증가 → SpriteKit은 y가 위로 증가하므로 뒤집습니다.
///
/// 씬은 창 크기를 그대로 따르고(`resizeFill`), 사무실은 줄이지 않습니다 (배율 1, M5(1)).
/// 사무실 크기가 창 크기를 따라가고, 들어가지 않는 행·서브는 `OfficeFloor`가 숨깁니다.
/// 창이 최소 크기(`OfficeLayout.minWidth`·`minHeight`)보다 작을 때만 줄입니다.
final class OfficeScene: SKScene {
    /// 무엇을 어떻게 보여 줄지
    enum Framing {
        /// 사무실 창: 사무실 전체를 둘레 여백 안쪽에 (창이 최소 크기보다 작을 때만 줄임)
        case office
        /// 미니 사무실 (M5(4)): 지도 y `top`부터 아래를 배율 1로 잘라 보여 줌 (한 행 띠)
        case band(top: Double)
    }

    let store: StageStore
    let framing: Framing
    /// 지도 좌표(사무실 크기)로 그리는 층. 창 크기에 맞춰 크기와 위치만 바뀝니다.
    let world = SKNode()
    private let furniture = SKNode()
    /// 움직이는 가구 (안마 의자 롤러, 긴 명령을 기다리는 모니터). 그림이 바뀔 때만 다시 만듭니다.
    private let liveFurniture = SKNode()
    private var shownLiveLayers: [ArtLayer] = []
    private var shownLiveHeight = 0.0
    /// 밤에 사람 있는 책상의 불빛 (M6(6)). 바닥 바로 위, 가구 아래. 자리가 바뀔 때만 다시 만듭니다.
    private let deskLights = SKNode()
    private var shownDeskLights: (seats: [MapPoint], height: Double)?
    /// 조명이 바뀌는 순간 덮어 두었다가 서서히 지우는 이전 화면 한 장
    private var fadingSnapshot: SKSpriteNode?
    /// 지금 칠한 배경색의 조명
    private var shownBackground: Lighting?
    /// 말풍선·상태 칩·아이콘·효과 층 (가구와 직원 모두의 위)
    private let overlayLayer = SKNode()
    private var overlays: [String: OverlayNode] = [:]
    private var characters: [AgentID: CharacterNode] = [:]
    /// 마우스를 올린 직원 (말풍선 전체 문구를 보여줍니다)
    private var hoveredAgent: AgentID?
    /// 클릭으로 고른 직원. 빈 곳을 누르면 nil로 돌아갑니다.
    var onSelect: ((AgentID?) -> Void)?
    /// 캐릭터 더블클릭 (M5(7)): 그 세션의 Claude 앱이나 터미널을 앞으로
    var onActivate: ((AgentID) -> Void)?
    /// 마우스를 올린 캐릭터의 도움말 ("메인1 · 더블클릭하면 앱으로 이동"). 뷰의 toolTip으로 보여 줍니다.
    var hoverHelp: ((AgentID) -> String?)?
    /// 미니에서 캐릭터를 한 번 누른 뒤 두 번째 클릭을 기다리는 중 (그동안은 사무실 창을 열지 않음)
    private var pendingClick: (agent: AgentID, work: DispatchWorkItem)?
    /// 사무실 영역 크기가 바뀜 (모델이 들어가는 수를 다시 셉니다). 띠면 보이는 지도 폭(왼쪽 여백 뺀 폭)과 높이.
    var onViewportChange: ((CGSize) -> Void)?
    /// 띠에서 끌어 창을 옮긴 뒤 (모서리에 붙이기)
    var onWindowDragged: (() -> Void)?
    /// 띠에서 오른쪽 클릭·Ctrl+클릭 (M6(11)): 누른 직원(빈 곳이면 nil)과 이벤트. 미니 패널이 메뉴를 엽니다.
    var onContextMenu: ((AgentID?, NSEvent) -> Void)?
    /// 띠에서 직원 요소의 VoiceOver 메뉴 보기 (M6(11))
    var onAccessibilityMenu: ((AgentID) -> Bool)?
    private var reportedSize: CGSize?
    var selectedAgent: AgentID? {
        didSet {
            guard oldValue != selectedAgent else { return }
            if let oldValue { characters[oldValue]?.isSelected = false }
            if let selectedAgent { characters[selectedAgent]?.isSelected = true }
            // 키보드로 고르면 VoiceOver 커서도 그 사람에게 (장면에 키보드 초점이 있을 때)
            if let selectedAgent, keyboardFocusedAgent == selectedAgent, NSWorkspace.shared.isVoiceOverEnabled {
                NSAccessibility.post(element: characterElement(for: selectedAgent), notification: .focusedUIElementChanged)
            }
        }
    }

    // MARK: - 접근성 (M6(7))

    /// 사람마다 한 번 만든 VoiceOver 요소 (`SceneAccessibility.swift`)
    var characterElements: [AgentID: CharacterAccessibilityElement] = [:]
    var accessibilityExtras = AccessibilityExtras()
    /// 요소가 읽을 목록 줄 (모델의 지금 `Roster`에서 찾음)
    var accessibilityRow: ((AgentID) -> RosterRow?)?
    /// 행이 모자라 통째로 숨긴 행 요약 (사무실 창만)
    var accessibilityHiddenRows: (() -> String?)?
    /// 마지막으로 VoiceOver에 알린 "+N" (사람이 오가는 것은 노드를 만들거나 지울 때 압니다)
    private var announcedHidden: [TeamID: Int]?
    /// 상태 글자가 바뀌었는지 보려고 마지막으로 읽힌 문구
    private var spokenLabels: [AgentID: String] = [:]

    /// 미니 사무실 띠인지
    var isBand: Bool {
        if case .band = framing { return true }
        return false
    }

    /// 키보드 초점이 장면에 있을 때 고른 사람 (VoiceOver 초점 요소)
    var keyboardFocusedAgent: AgentID? {
        guard let view, view.window?.firstResponder === view else { return nil }
        return selectedAgent
    }

    func characterNodeExists(_ id: AgentID) -> Bool { characters[id] != nil }

    /// 캐릭터의 화면 좌표 사각형 (VoiceOver 커서 상자)
    func accessibilityScreenFrame(of id: AgentID) -> NSRect {
        guard let view, let node = characters[id] else { return .zero }
        let frame = node.hitFrame
        let a = convert(CGPoint(x: frame.minX, y: frame.minY), from: world)
        let b = convert(CGPoint(x: frame.maxX, y: frame.maxY), from: world)
        let p = view.convert(a, from: self), q = view.convert(b, from: self)
        return NSAccessibility.screenRect(
            fromView: view, rect: NSRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y)))
    }

    /// 사람이 오가거나 "+N"이 바뀌었으면 VoiceOver에 알립니다 (바뀐 때만, VoiceOver가 켜져 있을 때만).
    /// 매 프레임 부르지만 바뀐 게 없으면 작은 사전 비교 하나로 끝납니다.
    private func noteAccessibilityMembers(_ stage: Stage, membersChanged: Bool) {
        let hidden = stage.hiddenCounts
        guard membersChanged || announcedHidden != hidden else { return }
        announcedHidden = hidden
        characterElements = characterElements.filter { characters[$0.key] != nil }
        spokenLabels = spokenLabels.filter { characters[$0.key] != nil }
        guard let view, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: view, notification: .layoutChanged)
    }

    /// 목록(`Roster`)이 바뀐 뒤 모델이 부릅니다: 읽는 문구가 바뀐 요소에만 `titleChanged`
    func accessibilityRosterChanged() {
        guard view != nil, NSWorkspace.shared.isVoiceOverEnabled else {
            spokenLabels.removeAll()
            return
        }
        for (id, element) in characterElements {
            guard let label = element.accessibilityLabel() else { continue }
            if let old = spokenLabels[id], old != label {
                NSAccessibility.post(element: element, notification: .titleChanged)
            }
            spokenLabels[id] = label
        }
    }

    /// 키보드로 다음 사람 고르기 (사무실 창). 끝을 넘으면 false (Tab이면 장면 밖으로 초점을 넘김).
    @discardableResult
    func moveSelection(_ move: SceneNavigation.Move) -> Bool {
        guard let next = SceneNavigation.target(from: selectedAgent, move: move, stage: store.stage) else { return false }
        onSelect?(next)
        return true
    }

    /// 시스템 "대비 증가"가 바뀜: 가구(명패)를 다시 굽고 칩·배지를 새 테두리로
    func setHighContrast(_ on: Bool) {
        guard store.highContrast != on else { return }
        store.highContrast = on
        // 칩·배지는 다음 장에서 도형이 달라져 저절로 다시 만들어집니다
        furnitureKey = nil
    }

    init(store: StageStore, framing: Framing = .office) {
        self.store = store
        self.framing = framing
        super.init(size: CGSize(width: OfficeLayout.defaultWidth, height: OfficeLayout.defaultHeight))
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = Swatch.floor.color.skColor
        addChild(world)
        deskLights.zPosition = -99_999
        world.addChild(deskLights)
        world.addChild(furniture)
        world.addChild(liveFurniture)
        overlayLayer.zPosition = 1_000_000
        world.addChild(overlayLayer)
    }

    /// 사무실 창이 화면에 보이는지 (장식성 효과음은 보일 때만 울립니다, 설계서 §11.3)
    var isVisibleOnScreen: Bool {
        guard let window = view?.window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    /// 창을 닫으면 SwiftUI가 장면을 멈춘 채로 두기도 해서 장면 멈춤은 풀고, 뷰는 지금 빈도대로 둡니다
    /// (안 보이는 동안 멈춘 뷰는 창이 다시 보이면 모델이 `applyPace`로 풂)
    func resumeIfPaused() {
        if isPaused { isPaused = false }
        applyPace(pace)
    }

    /// 지금 그리기 빈도 (M6(1)). 모델이 무대를 흘릴 때마다 정해 줍니다.
    private(set) var pace: RenderPace = .active
    /// 마지막으로 뷰의 멈춤을 푼 때 (멈춤 감시는 그 뒤 0.5초부터)
    private var resumedAt = Date.distantPast

    /// 그리기 빈도를 맞춥니다 (설계서 §8.3, M6(1)).
    ///
    /// - 멈춤(안 보임): SKView를 멈춥니다. 멈추지 않은 SKView는 그릴 게 없어도 디스플레이 링크가 vsync(120Hz)마다 메인 스레드를 깨웁니다.
    /// - 일하는 중·잔잔함·잠잠함: SKView는 멈춰 두고, 모델이 무대를 흘릴 때마다(15·6·3Hz) `renderOneFrame`으로 한 장씩만 그립니다.
    ///   `preferredFramesPerSecond`를 낮추는 것만으로는 디스플레이 링크가 그대로 120Hz로 돌아 CPU가 줄지 않았습니다
    ///   (M6(1) 측정: 미니만 보일 때 12fps 2.6% → 6fps로 낮춰도 2.6%).
    /// - 빠른 움직임: 30fps로 계속 그립니다.
    ///
    /// 움직임 단계에서 보이는데 0.5초 넘게 그리지 않았으면 그리기를 다시 시작합니다. SwiftUI는 닫은 사무실 창을 다시 열 때 같은 창을 다시 보여 주는데,
    /// 그 안의 SKView는 창이 닫힐 때 멈춘 그리기를 다시 시작하지 않습니다(M5(4) 화면 확인: 미니 → 사무실 창에서 캐릭터가 멈춤.
    /// 일시 정지를 껐다 켜면 다시 그림). 잔잔함 단계는 한 장마다 껐다 켜므로 같은 효과가 있습니다.
    func applyPace(_ next: RenderPace) {
        if next != pace {
            if next == .paused { pausedAt = Date() }
            pace = next
            PerfProbe.shared?.paceChanged(probeName, to: next)
        }
        guard let view else { return }
        switch next {
        case .paused:
            if !view.isPaused { view.isPaused = true }
        case .ambient, .calm, .working:
            // 뷰는 한 장을 그린 뒤 `didFinishUpdate`에서 다시 멈춥니다 (장면 멈춤은 뷰를 풀 때 같이 풀림)
            if view.preferredFramesPerSecond != RenderPacer.activeFPS { view.preferredFramesPerSecond = RenderPacer.activeFPS }
        case .active:
            if isPaused { isPaused = false }
            if view.preferredFramesPerSecond != RenderPacer.activeFPS { view.preferredFramesPerSecond = RenderPacer.activeFPS }
            let now = Date()
            if view.isPaused {
                view.isPaused = false
                resumedAt = now
            } else if now.timeIntervalSince(resumedAt) > 0.5, now.timeIntervalSince(lastUpdate) > 0.5 {
                view.isPaused = true
                view.isPaused = false
                resumedAt = now
            }
        }
    }

    /// 조명 전환 크로스페이드 길이 (초)
    static let lightingFade = 0.6

    /// 조명을 바꿉니다 (M6(6)). 보이는 중이면 지금 화면을 한 장 찍어 위에 덮고, 다음 장에서 가구를 새 조명으로 다시 구운 뒤
    /// 0.6초 동안 덮은 장을 서서히 지웁니다. 그동안 그리기 빈도는 모델이 "자리 잡는 중"(30fps)으로 올립니다.
    /// 안 보이면 바로 바꿉니다 (다음에 보일 때 새 조명으로 구움).
    func setLighting(_ lighting: Lighting) {
        guard store.lighting != lighting else { return }
        if pace != .paused, let view, view.window != nil, size.width > 1, size.height > 1,
            let texture = view.texture(from: self, crop: CGRect(origin: .zero, size: size))
        {
            fadingSnapshot?.removeFromParent()
            let snapshot = SKSpriteNode(texture: texture, size: size)
            snapshot.anchorPoint = .zero
            snapshot.position = .zero
            snapshot.zPosition = 2_000_000
            addChild(snapshot)
            fadingSnapshot = snapshot
            snapshot.run(.sequence([.fadeOut(withDuration: Self.lightingFade), .removeFromParent()])) { [weak self, weak snapshot] in
                if self?.fadingSnapshot === snapshot { self?.fadingSnapshot = nil }
            }
        }
        store.lighting = lighting
        furnitureKey = nil
    }

    /// 잔잔함·잠잠함 단계에서 한 장을 그립니다 (모델이 무대를 흘린 뒤 부름). 직전 장에서 한 장 간격이 지나지 않았으면 건너뜁니다.
    func renderOneFrame(now: Date = Date()) {
        guard isPulsed, let view, view.window != nil,
            now.timeIntervalSince(lastPulse) >= 1 / Double(pace.framesPerSecond) - 0.02
        else { return }
        if !view.isPaused {
            // 멈추지 않았는데 지난 요청 뒤로 한 장도 안 그렸으면 멈춘 그리기입니다 (창을 처음 열 때 재현, M5(4)와 같은 증상): 껐다 켭니다.
            // 그렸다면 곧 `didFinishUpdate`가 멈추므로 기다립니다.
            guard lastUpdate < lastPulse else { return }
            PerfProbe.shared?.count("\(probeName).restart")
            view.isPaused = true
        }
        lastPulse = now
        if isPaused { isPaused = false }
        view.isPaused = false
    }

    /// 깜빡임 길이: 잠잠함(3fps)에서는 늘려서 빠지지 않게 (M6(1))
    private var blinkDuration: Double { pace == .calm ? RenderPacer.calmBlinkDuration : 0.14 }

    /// 한 장씩 그리는 단계인지
    private var isPulsed: Bool { pace == .ambient || pace == .calm || pace == .working }

    private var lastPulse = Date.distantPast

    /// 디버그 계측에 쓰는 이름
    var probeName: String {
        if case .band = framing { return "mini" }
        return "office"
    }

    override func didFinishUpdate() {
        PerfProbe.shared?.frameRendered(probeName, visible: isVisibleOnScreen)
        // 잔잔함·잠잠함: 이 장을 그린 뒤(같은 vsync 콜백이 끝난 뒤) 다시 멈춥니다
        if isPulsed, let view {
            DispatchQueue.main.async { [weak self, weak view] in
                guard self?.isPulsed == true else { return }
                view?.isPaused = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)는 쓰지 않습니다")
    }

    override func didMove(to view: SKView) {
        // 창을 닫으면 SwiftUI가 장면을 멈춘 채로 두기도 해서, 다시 보일 때 풀어 줍니다 (M5(4) 화면 확인: 미니 → 사무실 창에서 캐릭터가 멈춤)
        resumeIfPaused()
        furnitureKey = nil
        view.window?.acceptsMouseMovedEvents = true
        sync()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        sync()
    }

    /// 마지막으로 그린 때 (그리기가 멈췄는지 보려고)
    private(set) var lastUpdate = Date.distantPast
    override func update(_ currentTime: TimeInterval) {
        lastUpdate = Date()
        sync()
    }

    private func sync() {
        if reportedSize != size, size.width > 1, size.height > 1 {
            reportedSize = size
            // 사무실은 둘레 여백 안쪽 크기를 따릅니다 (띠는 왼쪽 여백만)
            let pad = OfficeLayout.padding * 2
            switch framing {
            case .office: onViewportChange?(CGSize(width: max(size.width - pad, 1), height: max(size.height - pad, 1)))
            case .band: onViewportChange?(CGSize(width: max(size.width - pad / 2, 1), height: size.height))
            }
        }
        let stage = store.stage
        let height = stage.layout.height
        let extent = fitWorld(officeHeight: height)
        // 가구가 바뀌었는지는 0.25초마다만 봅니다 (명패 계산이 매 프레임 하기엔 무거움). 크기가 바뀌면 바로.
        let now = Date()
        if bakedGeneration != ShapeBaker.generation {
            bakedGeneration = ShapeBaker.generation
            furnitureKey = nil
            shownLiveLayers = []
        }
        if furnitureKey == nil || now.timeIntervalSince(furnitureCheckedAt) >= 0.25 || extent != lastExtent {
            furnitureCheckedAt = now
            lastExtent = extent
            rebuildFurnitureIfNeeded(stage, extent: extent)
        }
        rebuildLiveFurnitureIfNeeded(stage)
        rebuildDeskLightsIfNeeded(stage)
        let lighting = store.lighting
        if shownBackground != lighting {
            shownBackground = lighting
            backgroundColor = Swatch.floor.color.lit(lighting).skColor
        }

        var present = Set<AgentID>()
        var membersChanged = false
        for actor in stage.sortedActors {
            present.insert(actor.id)
            let node: CharacterNode
            if let existing = characters[actor.id] {
                node = existing
            } else {
                membersChanged = true
                let colorIndex = stage.teams[actor.agent.teamID]?.colorIndex ?? 0
                node = CharacterNode(agent: actor.agent, teamColor: Swatch.teamColors[colorIndex % Swatch.teamColors.count].color.skColor)
                node.isSelected = actor.id == selectedAgent
                node.alpha = 0
                node.run(.fadeIn(withDuration: 0.2))
                world.addChild(node)
                characters[actor.id] = node
            }
            node.apply(actor, time: stage.time, sceneHeight: height, blinkDuration: blinkDuration, lighting: lighting)
        }
        for (id, node) in characters where !present.contains(id) {
            characters[id] = nil
            membersChanged = true
            node.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        }
        noteAccessibilityMembers(stage, membersChanged: membersChanged)
        syncOverlays(stage, extent: extent)
    }

    /// 말풍선·상태 칩·아이콘을 무대에서 계산한 그대로 옮깁니다 (배치와 줄임은 OfficeStage의 Overlay가 정함)
    private func syncOverlays(_ stage: Stage, extent: MapRect) {
        let height = stage.layout.height
        let visible: MapRect
        switch framing {
        case .office: visible = MapRect(max(extent.x, 0), 0, min(extent.width, stage.layout.width), min(extent.height, height))
        // 띠: 잘라 보여 주는 영역 안에 말풍선을 가둡니다 (왼쪽 둘레 여백은 빼고)
        case .band: visible = MapRect(0, extent.y, extent.width + extent.x, extent.height)
        }
        let options = OverlayOptions(
            privacy: store.privacy, displayScale: world.xScale, hovered: hoveredAgent, bounds: visible, lighting: store.lighting,
            highContrast: store.highContrast)
        var present = Set<String>()
        for (index, item) in Overlay.items(for: stage, options: options).enumerated() {
            present.insert(item.id)
            let node = overlays[item.id] ?? {
                let node = OverlayNode()
                overlayLayer.addChild(node)
                overlays[item.id] = node
                return node
            }()
            node.apply(item, sceneHeight: height)
            node.zPosition = Double(index)
        }
        for (id, node) in overlays where !present.contains(id) {
            overlays[id] = nil
            node.removeFromParent()
        }
    }

    /// 움직이는 가구 그림의 시각 단위 (초). 롤러(2.6초 주기)·모니터(3초 주기)가 이 단위로 같은 그림을 되풀이해서 구운 텍스처를 다시 씁니다.
    private static let liveFurnitureStep = 1.0 / 15

    private func rebuildLiveFurnitureIfNeeded(_ stage: Stage) {
        let time = (stage.time / Self.liveFurnitureStep).rounded(.down) * Self.liveFurnitureStep
        let layers = OfficeArt.liveLayers(stage: stage, time: time, lighting: store.lighting)
        // 지도 높이가 바뀌면(창 크기 조절) 위아래를 뒤집는 기준이 달라지므로 그림이 같아도 다시 만듭니다
        // (M5(4) 화면 확인: 창을 키우면 안마 의자 롤러가 의자 한참 아래에 남아 있었음)
        let height = stage.layout.height
        guard layers != shownLiveLayers || height != shownLiveHeight else { return }
        shownLiveLayers = layers
        shownLiveHeight = height
        liveFurniture.removeAllChildren()
        for layer in layers {
            // 구운 텍스처는 캐시에서 다시 씁니다 (M6(1) 측정: 매 프레임 도형 노드를 새로 만들면 Metal 버퍼 할당·해제가 사무실 창 CPU의 절반)
            let node = ArtNodes.node(for: layer.shapes, colors: nil)
            node.position = CGPoint(x: 0, y: height)
            node.zPosition = layer.depth
            liveFurniture.addChild(node)
        }
    }

    /// 밤에 사람 있는 책상의 불빛 (M6(6)). 바닥을 다시 굽지 않고 책상마다 작은 텍스처(캐시에서 다시 씀)만 바꿉니다.
    private func rebuildDeskLightsIfNeeded(_ stage: Stage) {
        let seats = store.lighting == .night ? OfficeArt.litDesks(stage: stage) : []
        let height = stage.layout.height
        if let shown = shownDeskLights, shown.seats == seats, shown.height == height { return }
        shownDeskLights = (seats, height)
        deskLights.removeAllChildren()
        for seat in seats {
            let node = ArtNodes.node(for: OfficeArt.deskLight(at: seat), colors: nil)
            node.position = CGPoint(x: 0, y: height)
            deskLights.addChild(node)
        }
    }

    // MARK: - 클릭

    /// 사무실 창: 한 번 누르면 바로 고르고(빈 곳이면 닫기), 두 번째 클릭(더블클릭)이면 그 세션으로 이동합니다.
    /// 미니 사무실: 끌면 패널을 옮기고, 빈 곳을 누르면 바로 사무실 창을 엽니다. 캐릭터를 누르면 더블클릭 간격만큼 기다려
    /// 두 번째 클릭이 없으면 사무실 창을 열어 그 사람을 고르고, 있으면 미니는 그대로 두고 그 세션으로 이동합니다
    /// (첫 클릭에 미니가 숨으면 두 번째 클릭을 받을 수 없어서).
    override func mouseDown(with event: NSEvent) {
        let point = event.location(in: world)
        let hit = character(at: point)
        if case .band = framing, event.modifierFlags.contains(.control), let onContextMenu {
            cancelPendingClick()
            onContextMenu(hit, event)
            return
        }
        if case .band = framing, let window = view?.window {
            if event.clickCount >= 2, let pending = pendingClick {
                pending.work.cancel()
                pendingClick = nil
                _ = MiniWindowDrag.track(event, in: window)
                onActivate?(pending.agent)
                return
            }
            if MiniWindowDrag.track(event, in: window) {
                cancelPendingClick()
                onWindowDragged?()
            } else if let hit {
                cancelPendingClick()
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingClick = nil
                    self?.onSelect?(hit)
                }
                pendingClick = (hit, work)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.miniClickDelay, execute: work)
            } else {
                cancelPendingClick()
                onSelect?(nil)
            }
            return
        }
        if event.clickCount >= 2, let hit {
            onSelect?(hit)
            onActivate?(hit)
            return
        }
        onSelect?(hit)
    }

    /// 미니 오른쪽 클릭 (M6(11)): 누른 직원과 함께 메뉴. 사무실 창은 예전처럼 아무 일도 하지 않습니다.
    override func rightMouseDown(with event: NSEvent) {
        guard case .band = framing, let onContextMenu else { return super.rightMouseDown(with: event) }
        cancelPendingClick()
        onContextMenu(character(at: event.location(in: world)), event)
    }

    /// 미니에서 캐릭터 한 번 누름을 확정하기까지 기다리는 시간 (시스템 더블클릭 간격, 너무 길면 0.4초)
    static var miniClickDelay: TimeInterval { min(NSEvent.doubleClickInterval, 0.4) }

    private func cancelPendingClick() {
        pendingClick?.work.cancel()
        pendingClick = nil
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(character(at: event.location(in: world)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ id: AgentID?) {
        guard id != hoveredAgent else { return }
        hoveredAgent = id
        view?.toolTip = id.flatMap { hoverHelp?($0) }
    }

    /// 겹쳐 있으면 앞(화면 아래쪽)에 선 직원을 고릅니다. 몸보다 조금 넓게 잡아 작은 캐릭터도 누르기 쉽게 합니다.
    private func character(at point: CGPoint) -> AgentID? {
        characters
            .filter { $0.value.hitFrame.contains(point) }
            .max { $0.value.zPosition < $1.value.zPosition }?
            .key
    }

    /// 사무실을 배율 1로 둘레 여백(`OfficeLayout.padding`) 안쪽 왼쪽 위에 둡니다. 창이 사무실 최소 크기보다 작을 때만 줄입니다.
    /// 돌려주는 값은 화면에 보이는 영역(지도 좌표)으로, 배경(벽·바닥)을 여백까지 이어 그립니다.
    private func fitWorld(officeHeight: Double) -> MapRect {
        let view = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        if case .band(let top) = framing {
            // 지도 (-여백, top)을 화면 왼쪽 위에 배율 1로
            let pad = OfficeLayout.padding
            world.setScale(1)
            world.position = CGPoint(x: pad, y: view.height - officeHeight + top)
            return MapRect(-pad, top, view.width, view.height)
        }
        let officeWidth = store.stage.layout.width
        let pad = OfficeLayout.padding
        let scale = OfficeLayout.displayScale(viewWidth: view.width - pad * 2, viewHeight: view.height - pad * 2)
        let left = max(pad * scale, (view.width - officeWidth * scale) / 2)
        let top = pad * scale
        world.setScale(scale)
        world.position = CGPoint(x: left, y: view.height - top - officeHeight * scale)
        return MapRect(-left / scale, -top / scale, view.width / scale, view.height / scale)
    }

    /// 가구를 다시 만들어야 하는지 가리는 값 (매 프레임 비교하므로 문자열을 만들지 않고 값 그대로 비교, M6(1))
    private struct FurnitureKey: Equatable {
        var fit: [Int]
        var layout: OfficeLayout
        var teams: [Team]
        var nameplates: [TeamID: [Seat: String]]
        var lighting: Lighting
        var contrast: Bool
    }

    private var furnitureKey: FurnitureKey?
    private var furnitureCheckedAt = Date.distantPast
    private var bakedGeneration = ShapeBaker.generation
    private var lastExtent: MapRect?

    /// 오래 안 보이면 가구 텍스처를 놓습니다 (다시 보이면 다음 장에서 다시 구움, M6(1) 메모리)
    func releaseFurnitureIfHidden(for seconds: TimeInterval, now: Date = Date()) {
        guard pace == .paused, furnitureKey != nil, now.timeIntervalSince(pausedAt) >= seconds else { return }
        furniture.removeAllChildren()
        liveFurniture.removeAllChildren()
        shownLiveLayers = []
        deskLights.removeAllChildren()
        shownDeskLights = nil
        furnitureKey = nil
        PerfProbe.shared?.count("\(probeName).released")
    }

    private var pausedAt = Date()

    private func rebuildFurnitureIfNeeded(_ stage: Stage, extent: MapRect) {
        let teams = stage.sortedTeams
        // 배경 크기는 4pt 단위로만 다시 그립니다 (창을 끄는 동안 매 프레임 다시 그리지 않도록)
        let key = FurnitureKey(
            fit: [extent.x, extent.width, extent.height].map { Int(($0 / 4).rounded()) }, layout: stage.layout, teams: teams,
            nameplates: stage.nameplates, lighting: store.lighting, contrast: store.highContrast)
        guard key != furnitureKey else { return }
        furnitureKey = key

        furniture.removeAllChildren()
        let height = stage.layout.height
        let layers = OfficeArt.layers(
            layout: stage.layout, teams: teams, nameplates: stage.nameplates, extent: extent, lounge: !stage.config.commonAreasAtDesk,
            lighting: store.lighting, contrast: store.highContrast)

        // 가구는 비트맵으로 구워 둡니다 (M6(1)). 깊이가 같은 층(한 행의 책상들, 의자들, 바닥·벽·표지)은 한 장으로 합칩니다:
        // 깊이가 같으면 SpriteKit도 넣은 순서대로 그리므로 순서가 같고, 그릴 노드 수가 줄어 매 프레임 순회 비용이 줄어듭니다.
        // 합친 묶음의 글자(명패·폴더 표지)는 도형 위에 그립니다 (같은 깊이의 다른 가구와 겹치지 않음).
        // 그림 좌표 (x, y) → 지도 (x, height - y)이므로 원점을 height만큼 올립니다.
        // 보이는 영역(지도 좌표, y 아래로) → 노드 안 좌표 (x, -y)
        let visible = CGRect(x: extent.x, y: -(extent.y + extent.height), width: extent.width, height: extent.height).insetBy(dx: -2, dy: -2)
        for group in Self.groupByDepth(layers) {
            let node = ArtNodes.node(for: group.shapes, colors: nil, clip: visible)
            node.position = CGPoint(x: 0, y: height)
            node.zPosition = group.depth == -.infinity ? -100_000 : group.depth
            furniture.addChild(node)
        }
    }

    /// 깊이가 같은 층을 처음 나온 순서대로 묶습니다. 층이 하나면 그대로, 여럿이면 글자가 아닌 도형을 먼저, 글자를 나중에.
    static func groupByDepth(_ layers: [ArtLayer]) -> [(depth: Double, shapes: [ArtShape])] {
        var order: [Double] = []
        var groups: [Double: [ArtLayer]] = [:]
        for layer in layers {
            if groups[layer.depth] == nil { order.append(layer.depth) }
            groups[layer.depth, default: []].append(layer)
        }
        return order.map { depth in
            let members = groups[depth]!
            if members.count == 1 { return (depth, members[0].shapes) }
            let shapes = members.flatMap(\.shapes)
            let isText: (ArtShape) -> Bool = { if case .text = $0.geometry { true } else { false } }
            return (depth, shapes.filter { !isText($0) } + shapes.filter(isText))
        }
    }
}

/// 종이인형 리그 캐릭터 노드 (설계서 §9.3). 부위는 한 번 만들고, 매 프레임 RigPose만 적용합니다.
final class CharacterNode: SKNode {
    private let colors: CharacterArt.Colors
    private let body = SKNode()
    /// 몸통 (팀장만 가슴에 별 배지. 승진하면 다시 그립니다)
    private let torso = SKNode()
    private var shownStar: Bool?
    private let leftLeg: SKNode
    private let rightLeg: SKNode
    /// 발밑 그림자 (밤에는 옅은 빛 웅덩이, M6(6))
    private let shadow = SKNode()
    private var shownShadow: Lighting?
    /// 소파·안마 의자에 앉은 다리. 몸의 숨쉬기·떨림을 따르지 않고, 가구 앞판보다 앞에 그립니다.
    private let seatedLegs = SKNode()
    private var shownSeat: LoungeSeat??
    private let hairBackPivot = SKNode()
    private let headPivot = SKNode()
    private let headContent = SKNode()
    private let eyes = SKNode()
    private let faceDetails = SKNode()
    private let leftArm: SKNode
    private let rightArm: SKNode
    private let handProp = SKNode()
    private let handGesture = SKNode()
    private let heldProp = SKNode()
    private let selectionRing: SKShapeNode
    private let appearance: Appearance
    private var shownExpression: FacialExpression?
    private var shownProp: Prop??
    private var shownHandGesture: BodyGesture?

    /// 그림 데이터(y 아래로 증가)를 노드 안의 좌표(y 위로 증가)로
    private static let local: (MapPoint) -> CGPoint = { CGPoint(x: $0.x, y: -$0.y) }

    var isSelected = false {
        didSet { selectionRing.isHidden = !isSelected }
    }

    /// 클릭 판정 영역 (부모 좌표). 발밑 그림자부터 머리 위까지를 조금 넉넉하게 잡습니다.
    var hitFrame: CGRect {
        calculateAccumulatedFrame().insetBy(dx: -4, dy: -4)
    }

    init(agent: Agent, teamColor: NSColor) {
        let appearance = agent.profile.appearance
        self.appearance = appearance
        colors = CharacterArt.colors(for: appearance)
        // 고른 직원 발밑에 팀 색 고리를 깝니다
        selectionRing = SKShapeNode(ellipseOf: CGSize(width: 46, height: 15))
        selectionRing.fillColor = teamColor.withAlphaComponent(0.55)
        selectionRing.strokeColor = Swatch.ink.color.skColor
        selectionRing.lineWidth = 1.6
        selectionRing.isAntialiased = true
        selectionRing.isHidden = true
        leftLeg = ArtNodes.node(for: CharacterArt.leftLeg, colors: colors)
        rightLeg = ArtNodes.node(for: CharacterArt.rightLeg, colors: colors)
        leftArm = ArtNodes.node(for: CharacterArt.arm, colors: colors)
        rightArm = ArtNodes.node(for: CharacterArt.arm, colors: colors)
        super.init()

        addChild(selectionRing)
        addChild(shadow)
        addChild(body)
        // 부모(직원 발 위치 깊이)에 더해지는 깊이: 소파 좌판·안마 의자 앞판보다 앞, 책상보다 뒤
        seatedLegs.zPosition = CharacterArt.seatedLegsDepth
        addChild(seatedLegs)

        body.addChild(leftLeg)
        body.addChild(rightLeg)

        // 머리는 목(머리 중심에서 20pt 아래)을 축으로 돕니다
        let neck = Self.local(CharacterArt.headOrigin + MapPoint(0, 20))
        hairBackPivot.position = neck
        headPivot.position = neck
        let hairBack = ArtNodes.node(for: CharacterArt.hairBack(style: appearance.hairStyle), colors: colors)
        hairBack.position = CGPoint(x: 0, y: 20)
        hairBackPivot.addChild(hairBack)
        body.addChild(hairBackPivot)

        body.addChild(torso)

        headContent.position = CGPoint(x: 0, y: 20)
        headPivot.addChild(headContent)
        headContent.addChild(ArtNodes.node(for: CharacterArt.face, colors: colors))
        eyes.position = Self.local(MapPoint(0, 1))  // 눈높이를 축으로 세로로 깜빡입니다
        headContent.addChild(eyes)
        headContent.addChild(faceDetails)
        body.addChild(headPivot)

        leftArm.position = Self.local(CharacterArt.leftShoulder)
        rightArm.position = Self.local(CharacterArt.rightShoulder)
        rightArm.addChild(handProp)
        rightArm.addChild(handGesture)
        body.addChild(leftArm)
        body.addChild(rightArm)

        heldProp.position = Self.local(CharacterArt.heldPropOrigin)
        body.addChild(heldProp)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)는 쓰지 않습니다")
    }

    func apply(_ actor: StageActor, time: Double, sceneHeight: Double, blinkDuration: Double, lighting: Lighting = .day) {
        position = CGPoint(x: actor.position.x, y: sceneHeight - actor.position.y)
        zPosition = actor.position.y

        if shownShadow != lighting {
            shownShadow = lighting
            shadow.removeAllChildren()
            shadow.addChild(ArtNodes.node(for: CharacterArt.shadow(lighting), colors: colors))
        }

        let star = actor.agent.isMain
        if shownStar != star {
            shownStar = star
            torso.removeAllChildren()
            torso.addChild(ArtNodes.node(for: CharacterArt.body(isLead: star), colors: colors))
        }
        if shownExpression != actor.expression {
            shownExpression = actor.expression
            rebuildFace(actor.expression)
        }
        if shownProp == nil || shownProp! != actor.prop {
            shownProp = .some(actor.prop)
            handProp.removeAllChildren()
            handProp.addChild(ArtNodes.node(for: CharacterArt.handProp(actor.prop), colors: colors))
            heldProp.removeAllChildren()
            heldProp.addChild(ArtNodes.node(for: CharacterArt.heldProp(actor.prop), colors: colors))
        }

        let handShape: BodyGesture? = CharacterArt.handGesture(actor.gesture).isEmpty ? nil : actor.gesture
        if shownHandGesture != handShape {
            shownHandGesture = handShape
            handGesture.removeAllChildren()
            handGesture.addChild(ArtNodes.node(for: CharacterArt.handGesture(handShape), colors: colors))
        }

        let seat = actor.loungeSeat
        if shownSeat == nil || shownSeat! != seat {
            shownSeat = .some(seat)
            seatedLegs.removeAllChildren()
            if let seat {
                seatedLegs.addChild(ArtNodes.node(for: CharacterArt.seatedLegs(seat), colors: colors))
            }
            leftLeg.isHidden = seat != nil
            rightLeg.isHidden = seat != nil
            shadow.isHidden = seat != nil
        }

        let pose = RigAnimator.pose(for: actor, time: time, blinkDuration: blinkDuration)
        body.position = CGPoint(x: 0, y: -pose.bob)
        body.xScale = pose.mirrored ? -1 : 1
        body.yScale = pose.stretch
        leftLeg.position = CGPoint(x: 0, y: -pose.leftLegLift)
        rightLeg.position = CGPoint(x: 0, y: -pose.rightLegLift)
        let neck = Self.local(CharacterArt.headOrigin + MapPoint(0, 20 + pose.headDrop))
        let headRotation = -pose.headRotation * .pi / 180
        headPivot.position = neck
        headPivot.zRotation = headRotation
        hairBackPivot.position = neck
        hairBackPivot.zRotation = headRotation
        eyes.yScale = pose.eyeScale
        leftArm.zRotation = -pose.leftArm * .pi / 180
        rightArm.zRotation = -pose.rightArm * .pi / 180
    }

    private func rebuildFace(_ expression: FacialExpression) {
        eyes.removeAllChildren()
        // 눈 도형을 눈높이(y=1) 기준으로 옮겨서 넣습니다
        eyes.addChild(ArtNodes.node(for: CharacterArt.eyes(expression).transformed(offset: MapPoint(0, -1)), colors: colors))
        faceDetails.removeAllChildren()
        let details = CharacterArt.blush(expression) + CharacterArt.mouth(expression) + CharacterArt.hairFront(style: appearance.hairStyle)
            + CharacterArt.brows(expression) + CharacterArt.accessory(appearance.accessory) + CharacterArt.effects(expression)
        faceDetails.addChild(ArtNodes.node(for: details, colors: colors))
        // 겹침 순서는 zPosition이 아니라 노드를 넣은 순서(얼굴 → 눈 → 세부)로 정합니다.
        // zPosition을 주면 팔(턱 괴기 손)보다 얼굴이 앞에 그려집니다.
    }
}

/// 말풍선·상태 칩·아이콘 하나. 도형이 바뀔 때만 다시 만들고, 매 프레임에는 위치·크기·투명도만 바꿉니다.
final class OverlayNode: SKNode {
    private var shownShapes: [ArtShape] = []

    func apply(_ item: OverlayItem, sceneHeight: Double) {
        if item.shapes != shownShapes {
            shownShapes = item.shapes
            removeAllChildren()
            addChild(ArtNodes.node(for: item.shapes, colors: nil) { label, shape in ArtNodes.fit(label, in: item, shape: shape) })
        }
        position = CGPoint(x: item.origin.x, y: sceneHeight - item.origin.y)
        setScale(item.scale)
        alpha = item.opacity
    }
}

/// 렌더러와 무관한 도형(ArtShape)을 SpriteKit 노드로
enum ArtNodes {
    /// 말풍선 글자가 어림한 폭보다 넓게 그려지면 상자 안에 들어오도록 가로로 살짝 줄입니다
    static func fit(_ label: SKLabelNode, in item: OverlayItem, shape: ArtShape) {
        guard item.kind == .bubble || item.kind == .pill,
              case .text(let string, _, let size, let bold, _, _) = shape.geometry else { return }
        let estimated = TextMetrics.width(string, size: size, bold: bold)
        let actual = label.frame.width
        if actual > estimated + 0.5, actual > 0 {
            label.xScale = estimated / actual
        }
    }

    /// 도형 묶음 → 노드 (노드 안 좌표 `(x, -y)`). 글자가 아닌 도형은 이어진 것끼리 비트맵 한 장으로 구워 스프라이트로 만들고
    /// (`ShapeBaker`, M6(1)), 글자는 SKLabelNode로 둡니다. 그리는 순서는 도형 순서 그대로입니다.
    /// - Parameter onLabel: 글자 노드를 만든 뒤 부름 (말풍선 글자 폭 맞추기)
    static func node(
        for shapes: [ArtShape], colors: CharacterArt.Colors?, clip: CGRect? = nil, onLabel: ((SKLabelNode, ArtShape) -> Void)? = nil
    ) -> SKNode {
        var parts: [SKNode] = []
        var run: [ArtShape] = []
        func flush() {
            guard !run.isEmpty else { return }
            parts.append(ShapeBaker.node(for: run, colors: colors, clip: clip))
            run.removeAll()
        }
        for shape in shapes {
            guard case .text = shape.geometry else {
                run.append(shape)
                continue
            }
            flush()
            let node = node(for: shape, colors: colors, transform: local)
            if let label = node as? SKLabelNode { onLabel?(label, shape) }
            parts.append(node)
        }
        flush()
        if parts.count == 1 { return parts[0] }
        let container = SKNode()
        for part in parts { container.addChild(part) }
        return container
    }

    /// 그림 데이터(y 아래로 증가)를 노드 안의 좌표(y 위로 증가)로
    static let local: (MapPoint) -> CGPoint = { CGPoint(x: $0.x, y: -$0.y) }

    /// 굽지 않은 도형 노드 묶음 (매 프레임 바뀌는 움직이는 가구용)
    static func unbakedNode(for shapes: [ArtShape], colors: CharacterArt.Colors?, transform: @escaping (MapPoint) -> CGPoint) -> SKNode {
        let container = SKNode()
        for shape in shapes {
            container.addChild(node(for: shape, colors: colors, transform: transform))
        }
        return container
    }

    static func node(for shape: ArtShape, colors: CharacterArt.Colors?, transform: (MapPoint) -> CGPoint) -> SKNode {
        if case .text(let string, let at, let size, let bold, let anchor, let baseline) = shape.geometry {
            let label = SKLabelNode(text: string)
            label.fontName = bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular"
            label.fontSize = size
            label.fontColor = shape.fill.map { color($0, colors) } ?? .black
            label.verticalAlignmentMode = .baseline
            switch anchor {
            case .start: label.horizontalAlignmentMode = .left
            case .middle: label.horizontalAlignmentMode = .center
            case .end: label.horizontalAlignmentMode = .right
            }
            var position = transform(at)
            if baseline == .central {
                // SKLabelNode의 .center는 글꼴의 위아래 여백까지 포함한 줄 높이의 가운데라서 글자가 위로 떠 보입니다.
                // 실제 글자 모양(한글과 대문자)의 높이 가운데를 기준점에 맞춥니다.
                position.y -= inkMidline(fontName: label.fontName ?? "", size: size)
            }
            label.position = position
            label.alpha = shape.opacity
            return label
        }
        let shapePath = path(shape.geometry, transform: transform)
        if shape.dash > 0, let stroke = shape.stroke {
            // SKShapeNode에는 점선이 없어서, 채우기와 점선 테두리를 따로 그립니다
            let container = SKNode()
            let fill = SKShapeNode(path: shapePath)
            fill.fillColor = shape.fill.map { color($0, colors) } ?? .clear
            fill.strokeColor = .clear
            fill.lineWidth = 0
            container.addChild(fill)
            let dashed = SKShapeNode(path: shapePath.copy(dashingWithPhase: 0, lengths: [shape.dash, shape.dash]))
            dashed.fillColor = .clear
            dashed.strokeColor = color(stroke, colors)
            dashed.lineWidth = shape.lineWidth
            dashed.lineCap = .round
            dashed.isAntialiased = true
            container.addChild(dashed)
            container.alpha = shape.opacity
            return container
        }
        let node = SKShapeNode(path: shapePath)
        node.fillColor = shape.fill.map { color($0, colors) } ?? .clear
        if let stroke = shape.stroke {
            node.strokeColor = color(stroke, colors)
            node.lineWidth = shape.lineWidth
        } else {
            node.strokeColor = .clear
            node.lineWidth = 0
        }
        node.lineJoin = .round
        node.lineCap = .round
        node.isAntialiased = true
        node.alpha = shape.opacity
        return node
    }

    private static var midlineCache: [String: CGFloat] = [:]

    /// 바닥선에서 글자 높이 가운데까지의 거리. 내림 획이 없는 "가H"의 글리프 경계로 잽니다.
    static func inkMidline(fontName: String, size: CGFloat) -> CGFloat {
        let key = "\(fontName)@\(size)"
        if let cached = midlineCache[key] { return cached }
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "가H", attributes: [.font: font]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let midline = bounds.midY
        midlineCache[key] = midline
        return midline
    }

    static func color(_ paint: Paint, _ colors: CharacterArt.Colors?) -> NSColor {
        SVGRenderer.resolve(paint, colors: colors).skColor
    }

    static func path(_ geometry: ArtShape.Geometry, transform: (MapPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        switch geometry {
        case .path(let commands):
            for command in commands {
                switch command {
                case .move(let p): path.move(to: transform(p))
                case .line(let p): path.addLine(to: transform(p))
                case .quad(let c, let p): path.addQuadCurve(to: transform(p), control: transform(c))
                case .cubic(let c1, let c2, let p): path.addCurve(to: transform(p), control1: transform(c1), control2: transform(c2))
                case .close: path.closeSubpath()
                }
            }
        case .circle(let center, let radius):
            path.addEllipse(in: box(center: center, rx: radius, ry: radius, transform: transform))
        case .ellipse(let center, let rx, let ry):
            path.addEllipse(in: box(center: center, rx: rx, ry: ry, transform: transform))
        case .rect(let rect, let radius):
            let a = transform(MapPoint(rect.x, rect.y))
            let b = transform(MapPoint(rect.maxX, rect.maxY))
            let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let corner = max(0, min(radius, frame.width / 2, frame.height / 2))
            if corner > 0 {
                path.addRoundedRect(in: frame, cornerWidth: corner, cornerHeight: corner)
            } else {
                path.addRect(frame)
            }
        case .text:
            break
        }
        return path
    }

    private static func box(center: MapPoint, rx: Double, ry: Double, transform: (MapPoint) -> CGPoint) -> CGRect {
        let c = transform(center)
        return CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2)
    }
}

extension ArtColor {
    var skColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
