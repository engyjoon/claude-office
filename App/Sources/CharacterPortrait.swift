import OfficeCore
import OfficeStage
import SwiftUI

/// 사무실 캐릭터와 같은 그림 데이터(CharacterArt.portrait)로 그린 얼굴 초상.
/// 메뉴 목록, 신원 카드, 직원 현황 패널에서 씁니다.
struct CharacterPortrait: View {
    let appearance: Appearance
    let isLead: Bool
    var tint: Color = Color(hex: 0xFFF8EC)

    var body: some View {
        Canvas { context, size in
            let frame = CharacterArt.portraitFrame
            let bounds = CGRect(origin: .zero, size: size)
            let circle = Path(ellipseIn: bounds)
            context.fill(circle, with: .color(tint))
            context.clip(to: circle)

            let scale = min(size.width / frame.width, size.height / frame.height)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -frame.x, y: -frame.y)

            let colors = CharacterArt.colors(for: appearance)
            for shape in CharacterArt.portrait(appearance, isLead: isLead) {
                if case .text = shape.geometry { continue }
                let path = Path(ArtNodes.path(shape.geometry) { CGPoint(x: $0.x, y: $0.y) })
                var layer = context
                layer.opacity = shape.opacity
                if let fill = shape.fill {
                    layer.fill(path, with: .color(Self.color(fill, colors)))
                }
                if let stroke = shape.stroke {
                    layer.stroke(
                        path, with: .color(Self.color(stroke, colors)),
                        style: StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .overlay(Circle().stroke(Color(hex: 0x3B3347).opacity(0.55), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private static func color(_ paint: Paint, _ colors: CharacterArt.Colors) -> Color {
        let c = SVGRenderer.resolve(paint, colors: colors)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}
