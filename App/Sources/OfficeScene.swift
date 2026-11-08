import AppKit
import OfficeCore
import OfficeStage
import SpriteKit

/// 무대 상태를 담아 두는 상자. AppModel이 매 프레임 갱신하고 씬이 읽습니다 (둘 다 메인 스레드).
final class StageStore {
    var stage = Stage()
}

/// SpriteKit 사무실 화면 (설계서 §8).
///
/// 무대(Stage)를 그대로 옮겨 그리기만 합니다. 판단과 타이밍은 모두 OfficeCore·OfficeStage에 있고,
/// 그림 데이터는 SVG 스냅숏과 같은 OfficeArt·CharacterArt를 씁니다.
/// 좌표 변환: 그림 데이터는 y가 아래로 증가 → SpriteKit은 y가 위로 증가하므로 뒤집습니다.
final class OfficeScene: SKScene {
    private let store: StageStore
    private let furniture = SKNode()
    private var characters: [AgentID: CharacterNode] = [:]
    private var furnitureSignature = ""

    init(store: StageStore) {
        self.store = store
        super.init(size: CGSize(width: OfficeLayout.width, height: OfficeLayout().height))
        scaleMode = .aspectFit
        anchorPoint = .zero
        backgroundColor = Swatch.floor.color.skColor
        addChild(furniture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)는 쓰지 않습니다")
    }

    override func didMove(to view: SKView) {
        furnitureSignature = ""
        sync()
    }

    override func update(_ currentTime: TimeInterval) {
        sync()
    }

    private func sync() {
        let stage = store.stage
        let height = stage.layout.height
        if abs(size.height - height) > 0.5 {
            size = CGSize(width: OfficeLayout.width, height: height)
        }
        rebuildFurnitureIfNeeded(stage)

        var present = Set<AgentID>()
        for actor in stage.sortedActors {
            present.insert(actor.id)
            let node: CharacterNode
            if let existing = characters[actor.id] {
                node = existing
            } else {
                node = CharacterNode(agent: actor.agent)
                node.alpha = 0
                node.run(.fadeIn(withDuration: 0.2))
                addChild(node)
                characters[actor.id] = node
            }
            node.apply(actor, time: stage.time, sceneHeight: height)
        }
        for (id, node) in characters where !present.contains(id) {
            characters[id] = nil
            node.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        }
    }

    private func rebuildFurnitureIfNeeded(_ stage: Stage) {
        let teams = stage.sortedTeams
        let plates = stage.nameplates.keys.sorted().map { team in
            team.raw + ":" + (stage.nameplates[team] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
        let signature = "\(stage.layout.islandCount)|" + teams.map { "\($0.island):\($0.name)" }.joined(separator: ",") + "|" + plates.joined(separator: ";")
        guard signature != furnitureSignature else { return }
        furnitureSignature = signature

        furniture.removeAllChildren()
        let height = stage.layout.height
        let layers = OfficeArt.layers(layout: stage.layout, teams: teams, nameplates: stage.nameplates)

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
    private let leftLeg: SKNode
    private let rightLeg: SKNode
    private let hairBackPivot = SKNode()
    private let headPivot = SKNode()
    private let headContent = SKNode()
    private let eyes = SKNode()
    private let faceDetails = SKNode()
    private let leftArm: SKNode
    private let rightArm: SKNode
    private let handProp = SKNode()
    private let heldProp = SKNode()
    private let appearance: Appearance
    private var shownExpression: FacialExpression?
    private var shownProp: Prop??

    /// 그림 데이터(y 아래로 증가)를 노드 안의 좌표(y 위로 증가)로
    private static let local: (MapPoint) -> CGPoint = { CGPoint(x: $0.x, y: -$0.y) }

    init(agent: Agent) {
        let appearance = agent.profile.appearance
        self.appearance = appearance
        colors = CharacterArt.colors(for: appearance)
        leftLeg = ArtNodes.node(for: CharacterArt.leftLeg, colors: colors, transform: Self.local)
        rightLeg = ArtNodes.node(for: CharacterArt.rightLeg, colors: colors, transform: Self.local)
        leftArm = ArtNodes.node(for: CharacterArt.arm, colors: colors, transform: Self.local)
        rightArm = ArtNodes.node(for: CharacterArt.arm, colors: colors, transform: Self.local)
        super.init()

        addChild(ArtNodes.node(for: CharacterArt.shadow, colors: colors, transform: Self.local))
        addChild(body)

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

        body.addChild(ArtNodes.node(for: CharacterArt.body(isLead: agent.role == .lead), colors: colors, transform: Self.local))

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

/// 렌더러와 무관한 도형(ArtShape)을 SpriteKit 노드로
enum ArtNodes {
    static func node(for shapes: [ArtShape], colors: CharacterArt.Colors?, transform: @escaping (MapPoint) -> CGPoint) -> SKNode {
        let container = SKNode()
        for shape in shapes {
            container.addChild(node(for: shape, colors: colors, transform: transform))
        }
        return container
    }

    static func node(for shape: ArtShape, colors: CharacterArt.Colors?, transform: (MapPoint) -> CGPoint) -> SKNode {
        if case .text(let string, let at, let size, let bold, let anchor) = shape.geometry {
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
            label.position = transform(at)
            label.alpha = shape.opacity
            return label
        }
        let node = SKShapeNode(path: path(shape.geometry, transform: transform))
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
