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

    private let store: StageStore
    let framing: Framing
    /// 지도 좌표(사무실 크기)로 그리는 층. 창 크기에 맞춰 크기와 위치만 바뀝니다.
    private let world = SKNode()
    private let furniture = SKNode()
    /// 움직이는 가구 (안마 의자 롤러, 긴 명령을 기다리는 모니터). 그림이 바뀔 때만 다시 만듭니다.
    private let liveFurniture = SKNode()
    private var shownLiveLayers: [ArtLayer] = []
    /// 말풍선·상태 칩·아이콘·효과 층 (가구와 직원 모두의 위)
    private let overlayLayer = SKNode()
    private var overlays: [String: OverlayNode] = [:]
    private var characters: [AgentID: CharacterNode] = [:]
    /// 마우스를 올린 직원 (말풍선 전체 문구를 보여줍니다)
    private var hoveredAgent: AgentID?
    private var furnitureSignature = ""
    /// 클릭으로 고른 직원. 빈 곳을 누르면 nil로 돌아갑니다.
    var onSelect: ((AgentID?) -> Void)?
    /// 사무실 영역 크기가 바뀜 (모델이 들어가는 수를 다시 셉니다). 띠면 보이는 지도 폭(왼쪽 여백 뺀 폭)과 높이.
    var onViewportChange: ((CGSize) -> Void)?
    /// 띠에서 빈 곳을 끌어 창을 옮긴 뒤 (모서리에 붙이기)
    var onWindowDragged: (() -> Void)?
    private var reportedSize: CGSize?
    var selectedAgent: AgentID? {
        didSet {
            guard oldValue != selectedAgent else { return }
            if let oldValue { characters[oldValue]?.isSelected = false }
            if let selectedAgent { characters[selectedAgent]?.isSelected = true }
        }
    }

    init(store: StageStore, framing: Framing = .office) {
        self.store = store
        self.framing = framing
        super.init(size: CGSize(width: OfficeLayout.defaultWidth, height: OfficeLayout.defaultHeight))
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = Swatch.floor.color.skColor
        addChild(world)
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:)는 쓰지 않습니다")
    }

    override func didMove(to view: SKView) {
        furnitureSignature = ""
        view.window?.acceptsMouseMovedEvents = true
        sync()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        sync()
    }

    override func update(_ currentTime: TimeInterval) {
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
        rebuildFurnitureIfNeeded(stage, extent: extent)
        rebuildLiveFurnitureIfNeeded(stage)

        var present = Set<AgentID>()
        for actor in stage.sortedActors {
            present.insert(actor.id)
            let node: CharacterNode
            if let existing = characters[actor.id] {
                node = existing
            } else {
                let colorIndex = stage.teams[actor.agent.teamID]?.colorIndex ?? 0
                node = CharacterNode(agent: actor.agent, teamColor: Swatch.teamColors[colorIndex % Swatch.teamColors.count].color.skColor)
                node.isSelected = actor.id == selectedAgent
                node.alpha = 0
                node.run(.fadeIn(withDuration: 0.2))
                world.addChild(node)
                characters[actor.id] = node
            }
            node.apply(actor, time: stage.time, sceneHeight: height)
        }
        for (id, node) in characters where !present.contains(id) {
            characters[id] = nil
            node.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        }
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
        let options = OverlayOptions(privacy: store.privacy, displayScale: world.xScale, hovered: hoveredAgent, bounds: visible)
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

    private func rebuildLiveFurnitureIfNeeded(_ stage: Stage) {
        let layers = OfficeArt.liveLayers(stage: stage)
        guard layers != shownLiveLayers else { return }
        shownLiveLayers = layers
        liveFurniture.removeAllChildren()
        let height = stage.layout.height
        for layer in layers {
            let node = ArtNodes.node(for: layer.shapes, colors: nil) { CGPoint(x: $0.x, y: height - $0.y) }
            node.zPosition = layer.depth
            liveFurniture.addChild(node)
        }
    }

    // MARK: - 클릭

    override func mouseDown(with event: NSEvent) {
        let point = event.location(in: world)
        let hit = character(at: point)
        if case .band = framing, hit == nil {
            // 미니 사무실: 빈 곳을 끌면 패널을 옮깁니다
            view?.window?.performDrag(with: event)
            onWindowDragged?()
            return
        }
        onSelect?(hit)
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredAgent = character(at: event.location(in: world))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredAgent = nil
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

    private func rebuildFurnitureIfNeeded(_ stage: Stage, extent: MapRect) {
        let teams = stage.sortedTeams
        let rows = stage.layout.rows.map { "\($0.team.raw)#\($0.desks)+\($0.hidden)@\($0.index)" }
        let plates = stage.nameplates.keys.sorted().map { team in
            team.raw + ":" + (stage.nameplates[team] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }

        // 배경 크기는 4pt 단위로만 다시 그립니다 (창을 끄는 동안 매 프레임 다시 그리지 않도록)
        let fit = [extent.x, extent.width, extent.height].map { String(Int(($0 / 4).rounded())) }.joined(separator: ",")
        let signature = [fit, "\(Int(stage.layout.width))x\(Int(stage.layout.height))", rows.joined(separator: ","),
            teams.map { "\($0.id.raw):\($0.name):\($0.colorIndex)" }.joined(separator: ","), plates.joined(separator: ";")].joined(separator: "|")
        guard signature != furnitureSignature else { return }
        furnitureSignature = signature

        furniture.removeAllChildren()
        let height = stage.layout.height
        let layers = OfficeArt.layers(layout: stage.layout, teams: teams, nameplates: stage.nameplates, extent: extent)

        // 바닥과 벽은 움직이지 않으므로 한 번 그려서 캐시합니다
        let background = SKEffectNode()
        background.shouldRasterize = true
        background.shouldEnableEffects = false
        background.zPosition = -100_000
        for layer in layers where layer.depth == -.infinity {
            background.addChild(ArtNodes.node(for: layer.shapes, colors: nil) { CGPoint(x: $0.x, y: height - $0.y) })
        }
        furniture.addChild(background)

        for layer in layers where layer.depth != -.infinity {
            let node = ArtNodes.node(for: layer.shapes, colors: nil) { CGPoint(x: $0.x, y: height - $0.y) }
            node.zPosition = layer.depth
            node.name = layer.name
            furniture.addChild(node)
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
    private let shadow: SKNode
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
        leftLeg = ArtNodes.node(for: CharacterArt.leftLeg, colors: colors, transform: Self.local)
        rightLeg = ArtNodes.node(for: CharacterArt.rightLeg, colors: colors, transform: Self.local)
        shadow = ArtNodes.node(for: CharacterArt.shadow, colors: colors, transform: Self.local)
        leftArm = ArtNodes.node(for: CharacterArt.arm, colors: colors, transform: Self.local)
        rightArm = ArtNodes.node(for: CharacterArt.arm, colors: colors, transform: Self.local)
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
        let hairBack = ArtNodes.node(for: CharacterArt.hairBack(style: appearance.hairStyle), colors: colors, transform: Self.local)
        hairBack.position = CGPoint(x: 0, y: 20)
        hairBackPivot.addChild(hairBack)
        body.addChild(hairBackPivot)

        body.addChild(torso)

        headContent.position = CGPoint(x: 0, y: 20)
        headPivot.addChild(headContent)
        headContent.addChild(ArtNodes.node(for: CharacterArt.face, colors: colors, transform: Self.local))
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

    func apply(_ actor: StageActor, time: Double, sceneHeight: Double) {
        position = CGPoint(x: actor.position.x, y: sceneHeight - actor.position.y)
        zPosition = actor.position.y

        let star = actor.agent.isMain
        if shownStar != star {
            shownStar = star
            torso.removeAllChildren()
            torso.addChild(ArtNodes.node(for: CharacterArt.body(isLead: star), colors: colors, transform: Self.local))
        }
        if shownExpression != actor.expression {
            shownExpression = actor.expression
            rebuildFace(actor.expression)
        }
        if shownProp == nil || shownProp! != actor.prop {
            shownProp = .some(actor.prop)
            handProp.removeAllChildren()
            handProp.addChild(ArtNodes.node(for: CharacterArt.handProp(actor.prop), colors: colors, transform: Self.local))
            heldProp.removeAllChildren()
            heldProp.addChild(ArtNodes.node(for: CharacterArt.heldProp(actor.prop), colors: colors, transform: Self.local))
        }

        let handShape: BodyGesture? = CharacterArt.handGesture(actor.gesture).isEmpty ? nil : actor.gesture
        if shownHandGesture != handShape {
            shownHandGesture = handShape
            handGesture.removeAllChildren()
            handGesture.addChild(ArtNodes.node(for: CharacterArt.handGesture(handShape), colors: colors, transform: Self.local))
        }

        let seat = actor.loungeSeat
        if shownSeat == nil || shownSeat! != seat {
            shownSeat = .some(seat)
            seatedLegs.removeAllChildren()
            if let seat {
                seatedLegs.addChild(ArtNodes.node(for: CharacterArt.seatedLegs(seat), colors: colors, transform: Self.local))
            }
            leftLeg.isHidden = seat != nil
            rightLeg.isHidden = seat != nil
            shadow.isHidden = seat != nil
        }

        let pose = RigAnimator.pose(for: actor, time: time)
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
        eyes.addChild(ArtNodes.node(for: CharacterArt.eyes(expression).transformed(offset: MapPoint(0, -1)), colors: colors, transform: Self.local))
        faceDetails.removeAllChildren()
        let details = CharacterArt.blush(expression) + CharacterArt.mouth(expression) + CharacterArt.hairFront(style: appearance.hairStyle)
            + CharacterArt.brows(expression) + CharacterArt.accessory(appearance.accessory) + CharacterArt.effects(expression)
        faceDetails.addChild(ArtNodes.node(for: details, colors: colors, transform: Self.local))
        // 겹침 순서는 zPosition이 아니라 노드를 넣은 순서(얼굴 → 눈 → 세부)로 정합니다.
        // zPosition을 주면 팔(턱 괴기 손)보다 얼굴이 앞에 그려집니다.
    }
}

/// 말풍선·상태 칩·아이콘 하나. 도형이 바뀔 때만 다시 만들고, 매 프레임에는 위치·크기·투명도만 바꿉니다.
final class OverlayNode: SKNode {
    private var shownShapes: [ArtShape] = []
    /// 그림 데이터(y 아래로 증가)를 노드 안의 좌표(y 위로 증가)로
    private static let local: (MapPoint) -> CGPoint = { CGPoint(x: $0.x, y: -$0.y) }

    func apply(_ item: OverlayItem, sceneHeight: Double) {
        if item.shapes != shownShapes {
            shownShapes = item.shapes
            removeAllChildren()
            for shape in item.shapes {
                let node = ArtNodes.node(for: shape, colors: nil, transform: Self.local)
                if let label = node as? SKLabelNode {
                    ArtNodes.fit(label, in: item, shape: shape)
                }
                addChild(node)
            }
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

    static func node(for shapes: [ArtShape], colors: CharacterArt.Colors?, transform: @escaping (MapPoint) -> CGPoint) -> SKNode {
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
