import AppKit
import OfficeCore
import OfficeStage
import SpriteKit

/// 종이인형 리그 캐릭터 노드 (설계서 §9.3). 부위는 한 번 만들고, 매 프레임 RigPose만 적용합니다.
///
/// 부위 텍스처는 만들 때의 배율(`bakeScale`)로 굽습니다. 창이 다른 배율의 화면으로 옮겨지면 장면이 노드를 새 배율로 다시 만듭니다 (개선 10).
final class CharacterNode: SKNode {
    /// 부위를 굽는 배율 (장면이 창의 배율과 `BakeLayer.character`로 정함)
    let bakeScale: CGFloat
    private let colors: CharacterArt.Colors
    private let body = SKNode()
    /// 몸통 (메인만 가슴에 별 배지. 승진하면 다시 그립니다)
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
    private let hairBack: SKNode
    /// 고른 직원 외곽선 (M6(15)): 팀 색. 부위마다 실루엣 노드를 부위보다 살짝 뒤(z −0.01·−0.02·−0.03)에 붙입니다.
    private let teamColor: ArtColor
    private var outlineNodes: [SKNode] = []
    private var shownOutline: OutlineKey?
    private let appearance: Appearance
    private var shownExpression: FacialExpression?
    private var shownProp: Prop??
    private var shownHandGesture: BodyGesture?

    /// 그림 데이터(y 아래로 증가)를 노드 안의 좌표(y 위로 증가)로
    private static let local: (MapPoint) -> CGPoint = { CGPoint(x: $0.x, y: -$0.y) }

    /// 고르면 다음 `apply`에서 몸 둘레 외곽선을 만들고, 풀면 바로 지웁니다 (머리 위 ▼는 오버레이가 그림)
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            removeOutline()
        }
    }

    /// 외곽선 모양을 정하는 것들. 하나라도 바뀌면 (고른 동안만) 외곽선을 다시 만듭니다. 텍스처는 굽기 캐시에서 다시 씁니다.
    private struct OutlineKey: Equatable {
        var lighting: Lighting
        var contrast: Bool
        var star: Bool
        var prop: Prop?
        var handGesture: BodyGesture?
        var seat: LoungeSeat?
    }

    /// 클릭 판정 영역 (부모 좌표). 발밑 그림자부터 머리 위까지를 조금 넉넉하게 잡습니다.
    var hitFrame: CGRect {
        calculateAccumulatedFrame().insetBy(dx: -4, dy: -4)
    }

    init(agent: Agent, teamColor: ArtColor, bakeScale: CGFloat) {
        let appearance = agent.profile.appearance
        self.bakeScale = bakeScale
        self.appearance = appearance
        self.teamColor = teamColor
        colors = CharacterArt.colors(for: appearance)
        hairBack = ArtNodes.node(for: CharacterArt.hairBack(style: appearance.hairStyle), colors: colors, scale: bakeScale)
        leftLeg = ArtNodes.node(for: CharacterArt.leftLeg, colors: colors, scale: bakeScale)
        rightLeg = ArtNodes.node(for: CharacterArt.rightLeg, colors: colors, scale: bakeScale)
        leftArm = ArtNodes.node(for: CharacterArt.arm, colors: colors, scale: bakeScale)
        rightArm = ArtNodes.node(for: CharacterArt.arm, colors: colors, scale: bakeScale)
        super.init()

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
        hairBack.position = CGPoint(x: 0, y: 20)
        hairBackPivot.addChild(hairBack)
        body.addChild(hairBackPivot)

        body.addChild(torso)

        headContent.position = CGPoint(x: 0, y: 20)
        headPivot.addChild(headContent)
        headContent.addChild(ArtNodes.node(for: CharacterArt.face, colors: colors, scale: bakeScale))
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

    func apply(_ actor: StageActor, time: Double, sceneHeight: Double, blinkDuration: Double, lighting: Lighting = .day, contrast: Bool = false) {
        position = CGPoint(x: actor.position.x, y: sceneHeight - actor.position.y)
        zPosition = actor.position.y

        if shownShadow != lighting {
            shownShadow = lighting
            shadow.removeAllChildren()
            shadow.addChild(ArtNodes.node(for: CharacterArt.shadow(lighting), colors: colors, scale: bakeScale))
        }

        let star = actor.agent.isMain
        if shownStar != star {
            shownStar = star
            torso.removeAllChildren()
            torso.addChild(ArtNodes.node(for: CharacterArt.body(isLead: star), colors: colors, scale: bakeScale))
        }
        if shownExpression != actor.expression {
            shownExpression = actor.expression
            rebuildFace(actor.expression)
        }
        if shownProp == nil || shownProp! != actor.prop {
            shownProp = .some(actor.prop)
            handProp.removeAllChildren()
            handProp.addChild(ArtNodes.node(for: CharacterArt.handProp(actor.prop), colors: colors, scale: bakeScale))
            heldProp.removeAllChildren()
            heldProp.addChild(ArtNodes.node(for: CharacterArt.heldProp(actor.prop), colors: colors, scale: bakeScale))
        }

        let handShape: BodyGesture? = CharacterArt.handGesture(actor.gesture).isEmpty ? nil : actor.gesture
        if shownHandGesture != handShape {
            shownHandGesture = handShape
            handGesture.removeAllChildren()
            handGesture.addChild(ArtNodes.node(for: CharacterArt.handGesture(handShape), colors: colors, scale: bakeScale))
        }

        let seat = actor.loungeSeat
        if shownSeat == nil || shownSeat! != seat {
            shownSeat = .some(seat)
            seatedLegs.removeAllChildren()
            if let seat {
                seatedLegs.addChild(ArtNodes.node(for: CharacterArt.seatedLegs(seat), colors: colors, scale: bakeScale))
            }
            leftLeg.isHidden = seat != nil
            rightLeg.isHidden = seat != nil
            shadow.isHidden = seat != nil
        }

        if isSelected {
            let key = OutlineKey(lighting: lighting, contrast: contrast, star: star, prop: actor.prop, handGesture: handShape, seat: seat)
            if shownOutline != key {
                removeOutline()
                buildOutline(key)
            }
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

    /// 고른 직원 외곽선 (M6(15)). 각 부위 노드에 그 부위 실루엣을 층마다 하나씩, 부위보다 뒤(z 음수)에 붙입니다.
    /// SpriteKit은 z를 장면 전체에서 정렬하므로(`ignoresSiblingOrder` 꺼짐) 모든 부위의 바깥 테가 모든 부위의 안쪽 테보다,
    /// 모든 테가 몸보다 먼저 그려집니다. 그래서 팔이 몸통에 겹친 곳 같은 안쪽에는 선이 생기지 않고 몸 둘레에만 테가 보입니다.
    /// 부위의 자식이라 숨쉬기·팔·고개 움직임을 그대로 따릅니다. 앉은 다리(+2)의 테는 소파 앞판(+1.5)보다 앞, 책상(+3)은 테 아래쪽을 덮습니다.
    private func buildOutline(_ key: OutlineKey) {
        shownOutline = key
        let layers = CharacterArt.outlineLayers(team: teamColor, lighting: key.lighting, contrast: key.contrast)
        func attach(_ shapes: [ArtShape], to parent: SKNode) {
            guard !shapes.isEmpty else { return }
            for (index, layer) in layers.enumerated() {
                let node = ArtNodes.node(for: CharacterArt.silhouette(shapes, color: layer.color, width: layer.width), colors: colors, scale: bakeScale)
                node.zPosition = -0.01 * Double(layers.count - index)
                parent.addChild(node)
                outlineNodes.append(node)
            }
        }
        if let seat = key.seat {
            attach(CharacterArt.seatedLegs(seat), to: seatedLegs)
        } else {
            attach(CharacterArt.leftLeg, to: leftLeg)
            attach(CharacterArt.rightLeg, to: rightLeg)
        }
        attach(CharacterArt.hairBack(style: appearance.hairStyle), to: hairBack)
        attach(CharacterArt.body(isLead: key.star), to: torso)
        attach(CharacterArt.headOutline(appearance), to: headContent)
        attach(CharacterArt.arm, to: leftArm)
        attach(CharacterArt.arm, to: rightArm)
        attach(CharacterArt.handProp(key.prop), to: handProp)
        attach(CharacterArt.handGesture(key.handGesture), to: handGesture)
        attach(CharacterArt.heldProp(key.prop), to: heldProp)
    }

    private func removeOutline() {
        for node in outlineNodes { node.removeFromParent() }
        outlineNodes.removeAll()
        shownOutline = nil
    }

    private func rebuildFace(_ expression: FacialExpression) {
        eyes.removeAllChildren()
        // 눈 도형을 눈높이(y=1) 기준으로 옮겨서 넣습니다
        eyes.addChild(ArtNodes.node(for: CharacterArt.eyes(expression).transformed(offset: MapPoint(0, -1)), colors: colors, scale: bakeScale))
        faceDetails.removeAllChildren()
        let details = CharacterArt.blush(expression) + CharacterArt.mouth(expression) + CharacterArt.hairFront(style: appearance.hairStyle)
            + CharacterArt.brows(expression) + CharacterArt.accessory(appearance.accessory) + CharacterArt.effects(expression)
        faceDetails.addChild(ArtNodes.node(for: details, colors: colors, scale: bakeScale))
        // 겹침 순서는 zPosition이 아니라 노드를 넣은 순서(얼굴 → 눈 → 세부)로 정합니다.
        // zPosition을 주면 팔(턱 괴기 손)보다 얼굴이 앞에 그려집니다.
    }
}
