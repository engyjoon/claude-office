import Foundation
import OfficeCore

/// 무대를 SVG로 그립니다. 맥 없이 사무실 장면을 눈으로 확인하는 디버그·문서용 렌더러입니다.
/// SpriteKit 렌더러와 같은 그림 데이터(OfficeArt, CharacterArt)와 같은 자세 계산(RigAnimator)을 씁니다.
public enum SVGRenderer {
    /// `overlay`가 nil이면 말풍선·상태 칩·아이콘·효과를 빼고 그립니다.
    public static func render(stage: Stage, overlay: OverlayOptions? = .init()) -> String {
        let layout = stage.layout
        let width = OfficeLayout.width
        let height = layout.height
        var body = ""
        let layers = OfficeArt.layers(layout: layout, teams: stage.sortedTeams, nameplates: stage.nameplates)

        for layer in layers where layer.depth == -.infinity {
            body += layer.shapes.map { element($0, colors: nil) }.joined()
        }
        enum Item {
            case layer(ArtLayer)
            case actor(StageActor)
            var depth: Double {
                switch self {
                case .layer(let layer): layer.depth
                case .actor(let actor): actor.position.y
                }
            }
        }
        var items: [Item] = layers.filter { $0.depth != -.infinity }.map(Item.layer)
        items += stage.sortedActors.map(Item.actor)
        items.sort { $0.depth < $1.depth }
        for item in items {
            switch item {
            case .layer(let layer): body += layer.shapes.map { element($0, colors: nil) }.joined()
            case .actor(let actor): body += character(actor, time: stage.time)
            }
        }
        // 말풍선·상태 칩·아이콘은 가구와 직원 모두의 위에 그립니다
        if let overlay {
            for item in Overlay.items(for: stage, options: overlay) {
                body += self.overlay(item)
            }
        }
        return """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(f(width)) \(f(height))" width="\(f(width))" height="\(f(height))" \
            font-family="Apple SD Gothic Neo, Noto Sans CJK KR, Noto Sans KR, WenQuanYi Zen Hei, sans-serif">\(body)</svg>
            """
    }

    static func overlay(_ item: OverlayItem) -> String {
        var transform = "translate(\(f(item.origin.x)),\(f(item.origin.y)))"
        if item.scale != 1 { transform += " scale(\(f(item.scale)))" }
        let opacity = item.opacity < 1 ? " opacity=\"\(f(item.opacity))\"" : ""
        return "<g class=\"\(item.kind.rawValue)\" transform=\"\(transform)\"\(opacity)>" + item.shapes.map { element($0, colors: nil) }.joined() + "</g>"
    }

    static func character(_ actor: StageActor, time: Double) -> String {
        let pose = RigAnimator.pose(for: actor, time: time)
        let colors = CharacterArt.colors(for: actor.agent.profile.appearance)
        let appearance = actor.agent.profile.appearance
        let e = actor.expression
        func group(_ transform: String, _ shapes: [ArtShape]) -> String {
            "<g transform=\"\(transform)\">" + shapes.map { element($0, colors: colors) }.joined() + "</g>"
        }
        let head = "translate(0,\(f(CharacterArt.headOrigin.y + pose.headDrop))) rotate(\(f(pose.headRotation)),0,20)"
        let eyes = "translate(0,1) scale(1,\(f(pose.eyeScale))) translate(0,-1)"
        var inner = ""
        inner += group("translate(0,\(f(pose.leftLegLift)))", CharacterArt.leftLeg)
        inner += group("translate(0,\(f(pose.rightLegLift)))", CharacterArt.rightLeg)
        inner += group(head, CharacterArt.hairBack(style: appearance.hairStyle))
        inner += group("", CharacterArt.body(isLead: actor.agent.role == .lead))
        inner += "<g transform=\"\(head)\">"
            + (CharacterArt.face + CharacterArt.blush(e)).map { element($0, colors: colors) }.joined()
            + group(eyes, CharacterArt.eyes(e))
            + (CharacterArt.mouth(e) + CharacterArt.hairFront(style: appearance.hairStyle) + CharacterArt.brows(e)
                + CharacterArt.accessory(appearance.accessory) + CharacterArt.effects(e)).map { element($0, colors: colors) }.joined()
            + "</g>"
        inner += group("translate(\(f(CharacterArt.leftShoulder.x)),\(f(CharacterArt.leftShoulder.y))) rotate(\(f(pose.leftArm)))", CharacterArt.arm)
        inner += group("translate(\(f(CharacterArt.rightShoulder.x)),\(f(CharacterArt.rightShoulder.y))) rotate(\(f(pose.rightArm)))", CharacterArt.arm + CharacterArt.handProp(actor.prop) + CharacterArt.handGesture(actor.gesture))
        inner += group("translate(\(f(CharacterArt.heldPropOrigin.x)),\(f(CharacterArt.heldPropOrigin.y)))", CharacterArt.heldProp(actor.prop))
        let scaleX = pose.mirrored ? -1.0 : 1.0
        return "<g transform=\"translate(\(f(actor.position.x)),\(f(actor.position.y)))\">"
            + CharacterArt.shadow.map { element($0, colors: colors) }.joined()
            + "<g transform=\"translate(0,\(f(pose.bob))) scale(\(f(scaleX)),\(f(pose.stretch)))\">\(inner)</g></g>"
    }

    /// 목록·카드용 얼굴 초상 하나를 SVG로 (앱의 CharacterPortrait와 같은 그림)
    public static func portrait(_ appearance: Appearance, isLead: Bool, size: Double = 96) -> String {
        let frame = CharacterArt.portraitFrame
        let colors = CharacterArt.colors(for: appearance)
        let body = CharacterArt.portrait(appearance, isLead: isLead).map { element($0, colors: colors) }.joined()
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(size))\" height=\"\(f(size))\" viewBox=\"\(f(frame.x)) \(f(frame.y)) \(f(frame.width)) \(f(frame.height))\">"
            + "<clipPath id=\"c\"><circle cx=\"\(f(frame.x + frame.width / 2))\" cy=\"\(f(frame.y + frame.height / 2))\" r=\"\(f(frame.width / 2))\"/></clipPath>"
            + "<circle cx=\"\(f(frame.x + frame.width / 2))\" cy=\"\(f(frame.y + frame.height / 2))\" r=\"\(f(frame.width / 2))\" fill=\"#FFF8EC\"/>"
            + "<g clip-path=\"url(#c)\">\(body)</g></svg>"
    }

    static func element(_ shape: ArtShape, colors: CharacterArt.Colors?) -> String {
        var attributes = ""
        if let fill = shape.fill {
            let color = resolve(fill, colors: colors)
            attributes += " fill=\"\(color.hex)\""
            if color.alpha < 1 { attributes += " fill-opacity=\"\(f(color.alpha))\"" }
        } else {
            attributes += " fill=\"none\""
        }
        if let stroke = shape.stroke {
            let color = resolve(stroke, colors: colors)
            attributes += " stroke=\"\(color.hex)\" stroke-width=\"\(f(shape.lineWidth))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
            if color.alpha < 1 { attributes += " stroke-opacity=\"\(f(color.alpha))\"" }
            if shape.dash > 0 { attributes += " stroke-dasharray=\"\(f(shape.dash)) \(f(shape.dash))\"" }
        }
        if shape.opacity < 1 { attributes += " opacity=\"\(f(shape.opacity))\"" }
        switch shape.geometry {
        case .path(let commands):
            return "<path d=\"\(VectorPath.svg(commands))\"\(attributes)/>"
        case .circle(let c, let r):
            return "<circle cx=\"\(f(c.x))\" cy=\"\(f(c.y))\" r=\"\(f(r))\"\(attributes)/>"
        case .ellipse(let c, let rx, let ry):
            return "<ellipse cx=\"\(f(c.x))\" cy=\"\(f(c.y))\" rx=\"\(f(rx))\" ry=\"\(f(ry))\"\(attributes)/>"
        case .rect(let rect, let radius):
            return "<rect x=\"\(f(rect.x))\" y=\"\(f(rect.y))\" width=\"\(f(rect.width))\" height=\"\(f(rect.height))\" rx=\"\(f(radius))\"\(attributes)/>"
        case .text(let string, let at, let size, let bold, let anchor, let baseline):
            let escaped = string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            return "<text x=\"\(f(at.x))\" y=\"\(f(at.y))\" font-size=\"\(f(size))\" text-anchor=\"\(anchor.rawValue)\"\(baseline == .central ? " dominant-baseline=\"central\"" : "")\(bold ? " font-weight=\"bold\"" : "")\(attributes)>\(escaped)</text>"
        }
    }

    public static func resolve(_ paint: Paint, colors: CharacterArt.Colors?) -> ArtColor {
        switch paint {
        case .swatch(let swatch): swatch.color
        case .color(let color): color
        case .skin: colors?.skin ?? ArtColor(0xFBDDC8)
        case .hair: colors?.hair ?? ArtColor(0x3B2F3A)
        case .top: colors?.top ?? ArtColor(0x9FD8C7)
        case .pants: colors?.pants ?? ArtColor(0x5D5670)
        }
    }

    static func f(_ value: Double) -> String {
        VectorPath.format(value)
    }
}
