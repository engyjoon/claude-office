import Foundation
import OfficeCore

/// 앱 아이콘 그림 (M6(3)): 노란 바탕에 헤드폰을 쓰고 웃는 직원 얼굴.
/// 사무실·직원 현황 초상과 같은 부위 도형(CharacterArt)을 키워서 씁니다.
/// 좌표는 1024×1024 캔버스이고 y가 아래로 증가합니다. 바탕은 macOS 아이콘 격자의 둥근 사각형(824, 여백 100)입니다.
/// PNG는 `scripts/make-app-icon.sh`(`make icon`)가 이 그림의 SVG로 만듭니다.
public enum AppIconArt {
    /// 64px 이상은 `full`, 16·32px는 덜어 낸 `small`
    public enum Detail: String, CaseIterable, Sendable {
        case full, small
    }

    /// 같은 캐릭터 색으로 칠할 도형 묶음
    public struct Group: Sendable {
        public var shapes: [ArtShape]
        public var appearance: Appearance?

        init(_ shapes: [ArtShape], appearance: Appearance? = nil) {
            self.shapes = shapes
            self.appearance = appearance
        }
    }

    public static let canvas = 1024.0
    public static let plate = MapRect(100, 100, 824, 824)
    public static let plateRadius = 185.0
    public static let plateFill = ArtColor(0xF7DE8B)
    /// 바탕 뒤쪽의 연한 원 (큰 크기만)
    static let haloFill = ArtColor(0xFBEBB2)

    /// 바탕 외곽선 굵기
    public static func plateLine(_ detail: Detail) -> Double {
        detail == .full ? 14 : 32
    }

    static let appearance = Appearance(skinTone: 1, hairStyle: 1, hairColor: 0, topColor: 4, accessory: .headphones, voice: 0)

    /// 바탕 위의 그림 (바탕 둥근 사각형 안으로 잘라 그립니다)
    public static func groups(_ detail: Detail) -> [Group] {
        let full = detail == .full
        // 머리 중심이 원점인 초상 좌표를 키워서 옮깁니다
        let scale = full ? 10.0 : 12.0
        let origin = MapPoint(512, 520)
        // 팔 없이 몸통(바탕 아래로 잘림)과 머리. 작은 크기는 볼터치·별 배지도 뺍니다.
        let toHead = MapPoint(-CharacterArt.headOrigin.x, -CharacterArt.headOrigin.y)
        let style = appearance.hairStyle
        var shapes = CharacterArt.hairBack(style: style)
            + CharacterArt.body(isLead: full).map { $0.transformed(offset: toHead) }
            + CharacterArt.face + CharacterArt.eyes(.happy)
            + (full ? CharacterArt.blush(.happy) : [])
            + CharacterArt.mouth(.happy) + CharacterArt.hairFront(style: style)
            + CharacterArt.accessory(appearance.accessory)
        shapes = shapes.transformed(scale: scale, offset: origin)
        if !full {
            // 작은 크기에서는 선이 사라지지 않게 굵게 (1024 기준 32 = 32px에서 1px)
            shapes = shapes.map { shape in
                guard shape.stroke != nil else { return shape }
                var shape = shape
                shape.lineWidth = max(shape.lineWidth, 32)
                return shape
            }
        }
        let halo: [ArtShape] = full ? [.circle(512, 480, 330, fill: .color(haloFill), outline: false)] : []
        return [Group(halo), Group(shapes, appearance: appearance)]
    }
}
