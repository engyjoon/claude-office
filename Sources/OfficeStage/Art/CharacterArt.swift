import Foundation
import OfficeCore

/// 종이인형 리그 캐릭터 그림 (설계서 §9.3). 처음 그림은 미리보기의 character()를 옮긴 것이고,
/// 2026-11-16에 얼굴·머리·옷·신발을 다시 그렸습니다 (리그의 축과 크기는 그대로).
/// 좌표는 발 위치가 원점이고 y가 아래로 증가합니다.
public enum CharacterArt {
    // MARK: - 색

    public static let skins: [UInt32] = [0xFBDDC8, 0xF3C6A5, 0xD9A47F, 0xB07A5C]
    public static let hairs: [UInt32] = [0x3B2F3A, 0x6B4A3A, 0xA86B4C, 0xE2B866, 0x5A5F8C, 0x8A5A6A, 0x2F2A33, 0x5A4256]
    public static let tops: [UInt32] = [0x9FD8C7, 0xF6B9A0, 0xC7BCEB, 0xF7DE8B, 0xA9D3F0, 0xF4A3B4]
    public static let pants: [UInt32] = [0x5D5670, 0x4F5A7A, 0x46506E]

    public struct Colors: Hashable, Sendable {
        public var skin: ArtColor
        public var hair: ArtColor
        public var top: ArtColor
        public var pants: ArtColor

        /// 귀 안쪽 같은 살의 그늘
        public var skinShade: ArtColor { skin.mixed(with: ArtColor(0xC0604F), amount: 0.3) }
        /// 머리카락 윤기
        public var hairShine: ArtColor { hair.mixed(with: ArtColor(0xFFFFFF), amount: 0.3) }
        /// 가르마·머리 결
        public var hairShade: ArtColor { hair.mixed(with: ArtColor(0x1E1826), amount: 0.35) }
        /// 옷의 솔기·소매 끝·후드
        public var topShade: ArtColor { top.mixed(with: ArtColor(0x5A4E66), amount: 0.26) }
        /// 줄무늬처럼 옷보다 밝은 무늬
        public var topLight: ArtColor { top.mixed(with: ArtColor(0xFFFFFF), amount: 0.55) }
    }

    public static func colors(for appearance: Appearance) -> Colors {
        Colors(
            skin: ArtColor(skins[abs(appearance.skinTone) % skins.count]),
            hair: ArtColor(hairs[abs(appearance.hairColor) % hairs.count]),
            top: ArtColor(tops[abs(appearance.topColor) % tops.count]),
            pants: ArtColor(pants[abs(appearance.hairColor + appearance.topColor) % pants.count])
        )
    }

    // MARK: - 옷차림

    /// 윗옷 모양. 외형 값에서 정해지므로 같은 직원은 언제나 같은 옷을 입습니다.
    public enum Outfit: Int, CaseIterable, Hashable, Sendable {
        /// 후드 티: 목 둘레 후드, 끈 두 가닥, 앞주머니
        case hoodie
        /// 셔츠: 흰 깃, 단추
        case shirt
        /// 줄무늬 반소매 티
        case stripes
        /// 카디건: 안에 받쳐 입은 흰 티, 단추
        case cardigan
    }

    public static func outfit(for appearance: Appearance) -> Outfit {
        let sum = abs(appearance.topColor) + abs(appearance.hairStyle) + abs(appearance.hairColor) + abs(appearance.skinTone)
        return Outfit.allCases[sum % Outfit.allCases.count]
    }

    // MARK: - 부위 위치

    public static let headOrigin = MapPoint(0, -62)
    /// 머리 꼭대기 (발 위치 기준 y, 머리 모양에 따라 조금씩 다름). 머리 위 그림(`Overlay`)은 이 위에 놓입니다.
    public static let crown = -85.0
    public static let leftShoulder = MapPoint(-14, -38)
    public static let rightShoulder = MapPoint(14, -38)
    public static let heldPropOrigin = MapPoint(0, -28)
    /// 눈높이 (머리 중심 기준 y). 깜빡일 때 눈을 이 높이를 축으로 세로로 줄입니다.
    public static let eyeLine = 2.5
    /// 눈 사이 거리의 절반
    static let eyeX = 8.5

    // MARK: - 몸

    public static let shadow: [ArtShape] = [.ellipse(0, 0, 17, 4.5, fill: .swatch(.shadow))]

    /// 발밑 그림자. 밤에는 옅은 빛 웅덩이로 바꿔, 어두운 바닥에서도 짙은 피부·머리 직원의 윤곽이 묻히지 않게 합니다 (M6(6)).
    public static func shadow(_ lighting: Lighting) -> [ArtShape] {
        guard lighting == .night else { return shadow }
        let light = ArtColor(0xFFE3A3)
        return [
            .ellipse(0, 0, 24, 6.5, fill: .color(light), opacity: 0.16),
            .ellipse(0, 0, 17, 4.5, fill: .color(light), opacity: 0.26),
        ]
    }

    // MARK: - 고른 직원 외곽선 (M6(15))

    /// 밤에 쓰는 밝은 테 색 (흰색 대신 따뜻한 흰색, 밤 조명 불빛과 어울리게)
    public static let nightOutlineEdge = ArtColor(0xFFF3D0)

    /// 외곽선 한 겹: 부위 도형을 이 색·굵기로 칠한 실루엣
    public struct OutlineLayer: Hashable, Sendable {
        public var color: ArtColor
        public var width: Double
    }

    /// 고른 직원 둘레에 까는 외곽선 층 (뒤에서 앞 순서). 부위마다 이 층들을 부위보다 뒤에 깔면,
    /// 바깥부터 (대비 증가면 잉크) → 밝은 테 → 팀 색 테가 몸 전체 둘레에 생깁니다.
    /// 굵기는 선 전체 폭이라 도형 가장자리 밖으로 절반씩 나옵니다 (밝은 테 4.5pt, 팀 색 2.75pt, 잉크 6pt).
    public static func outlineLayers(team: ArtColor, lighting: Lighting, contrast: Bool) -> [OutlineLayer] {
        var layers: [OutlineLayer] = []
        if contrast { layers.append(OutlineLayer(color: Swatch.ink.color, width: 12)) }
        layers.append(OutlineLayer(color: lighting == .night ? nightOutlineEdge : ArtColor(0xFFFFFF), width: 9))
        layers.append(OutlineLayer(color: team, width: 5.5))
        return layers
    }

    /// 부위 도형을 한 색 실루엣으로: 모든 도형을 그 색으로 채우고 굵은 같은 색 선을 두릅니다.
    /// 반투명 도형(앉은 다리 밑 그림자 같은 것)과 글자는 빼서 테가 엉뚱한 곳에 생기지 않게 합니다.
    public static func silhouette(_ shapes: [ArtShape], color: ArtColor, width: Double) -> [ArtShape] {
        shapes.compactMap { shape in
            if case .text = shape.geometry { return nil }
            if shape.opacity < 1 { return nil }
            if case .swatch(let swatch)? = shape.fill, swatch.color.alpha < 1 { return nil }
            if case .color(let c)? = shape.fill, c.alpha < 1 { return nil }
            var copy = shape
            copy.fill = shape.fill == nil ? nil : .color(color)
            copy.stroke = .color(color)
            copy.lineWidth = width
            copy.dash = 0
            return copy
        }
    }

    /// 외곽선용 머리 실루엣: 얼굴 원 + 귀 + 앞머리 + 액세서리 (표정 효과·눈·입은 얼굴 안이라 빼도 모양이 같습니다)
    public static func headOutline(_ appearance: Appearance) -> [ArtShape] {
        face + ears + hairFront(style: appearance.hairStyle) + accessory(appearance.accessory)
    }

    /// 신발 색 (흰 운동화)
    static let shoe = ArtColor(0xFFFBF3)
    /// 신발 밑창
    static let sole = ArtColor(0xD9D2E0)

    static func standingLeg(_ side: Double) -> [ArtShape] {
        // side −1 = 왼쪽(화면 왼쪽), +1 = 오른쪽
        let legX = side < 0 ? -10.0 : 1.5
        let shoeX = side < 0 ? -11.4 : 1.0
        return [
            .rect(legX, -17, 8.5, 14.5, r: 3.5, fill: .pants),
            .rect(shoeX, -6, 10.4, 6, r: 3, fill: .color(shoe), width: 1.6),
            .line("M\(shoeX + 1.6),-1.7 L\(shoeX + 8.8),-1.7", width: 1.1, color: .color(sole)),
        ]
    }

    public static let leftLeg: [ArtShape] = standingLeg(-1)
    public static let rightLeg: [ArtShape] = standingLeg(1)

    /// 앉은 다리를 그리는 깊이 (직원 발 위치 + 이 값). 소파 좌판(+1.5)·안마 의자 앞판(+1)보다 앞, 책상(+3)보다 뒤입니다.
    public static let seatedLegsDepth = 2.0

    /// 소파·안마 의자에 앉은 다리 (원점: 앉는 자리 = 서 있을 때의 발 위치).
    /// 앞으로 나온 허벅지가 무릎에서 끝나고, 종아리가 좌판 앞으로 내려와 발이 바닥(소파)·발판(안마 의자)에 닿습니다.
    /// 몸의 숨쉬기·떨림과 함께 움직이지 않고 가구 위에 놓여 있습니다.
    public static func seatedLegs(_ seat: LoungeSeat) -> [ArtShape] {
        let foot = seatedFootY(seat)
        let knee = -7.0
        return [
            .ellipse(0, foot + 1, 14, 3, fill: .swatch(.shadow)),
            // 종아리 (무릎 안쪽에서 발목까지)
            .rect(-9.5, knee - 2, 8, foot - knee, r: 4, fill: .pants),
            .rect(1.5, knee - 2, 8, foot - knee, r: 4, fill: .pants),
            // 발 (앞을 향한 발끝)
            .rect(-11.2, foot - 5, 10.4, 6, r: 3, fill: .color(shoe), width: 1.6),
            .rect(0.8, foot - 5, 10.4, 6, r: 3, fill: .color(shoe), width: 1.6),
            // 허벅지 (엉덩이에서 무릎까지, 몸 아랫단을 덮어 무릎에 앉은 느낌)
            .rect(-11.5, -20, 11, 20 + knee + 3, r: 5.5, fill: .pants),
            .rect(0.5, -20, 11, 20 + knee + 3, r: 5.5, fill: .pants),
        ]
    }

    /// 앉은 다리의 발끝 높이 (원점 기준). 소파는 좌판 아래 바닥, 안마 의자는 발판 위.
    public static func seatedFootY(_ seat: LoungeSeat) -> Double {
        switch seat {
        case .sofa: 13
        case .massageChair: 6
        }
    }

    /// 몸통 (윗옷). 메인은 가슴에 별 배지를 답니다.
    public static func body(isLead: Bool, outfit: Outfit = .hoodie) -> [ArtShape] {
        let torso = MapRect(-15, -44, 30, 30)
        var shapes: [ArtShape] = [ArtShape(.rect(torso, radius: 12), fill: .top, stroke: .swatch(.ink))]
        let white = Paint.swatch(.white)
        switch outfit {
        case .hoodie:
            shapes += [
                // 목 둘레 후드 (머리가 위쪽을 덮어 턱 아래 초승달만 보입니다)
                ArtShape(.ellipse(center: MapPoint(0, -42), rx: 11, ry: 4.2), fill: .topShade, stroke: .swatch(.ink), lineWidth: 1.4),
                // 끈 두 가닥 (길이가 조금 다름)
                .line("M-2.8,-38 L-3.2,-32.4", width: 2.6),
                .line("M-2.8,-38 L-3.2,-32.4", width: 1.3, color: white),
                .line("M2.8,-38 L3.1,-34", width: 2.6),
                .line("M2.8,-38 L3.1,-34", width: 1.3, color: white),
                // 앞주머니
                .line("M-8.6,-15.4 L-6.6,-21.6 L6.6,-21.6 L8.6,-15.4", width: 1.3, color: .topShade),
            ]
        case .shirt:
            shapes += [
                .line("M0,-39 L0,-14.8", width: 1.1, color: .topShade),
                ArtShape(.circle(center: MapPoint(0, -32.6), radius: 1.1), fill: white, stroke: .topShade, lineWidth: 0.8),
                ArtShape(.circle(center: MapPoint(0, -26.2), radius: 1.1), fill: white, stroke: .topShade, lineWidth: 0.8),
                ArtShape(.circle(center: MapPoint(0, -19.8), radius: 1.1), fill: white, stroke: .topShade, lineWidth: 0.8),
                // 흰 깃
                .path("M-0.4,-39.2 L-8.2,-42.6 L-6.2,-35.4 Z", fill: white, width: 1.2),
                .path("M0.4,-39.2 L8.2,-42.6 L6.2,-35.4 Z", fill: white, width: 1.2),
            ]
        case .stripes:
            shapes += [
                // 줄무늬 (둥근 모서리 안쪽 폭에 맞춤) → 몸 테두리를 다시 그려 가장자리를 정리
                .rect(-14.4, -36.4, 28.8, 3, fill: .topLight, outline: false),
                .rect(-15, -29.8, 30, 3, fill: .topLight, outline: false),
                .path("M-14.6,-23.2 L14.6,-23.2 L13.5,-20.2 L-13.5,-20.2 Z", fill: .topLight, outline: false),
                ArtShape(.rect(torso, radius: 12), stroke: .swatch(.ink)),
                .line("M-6,-40.6 Q0,-36.8 6,-40.6", width: 1.5, color: .topShade),
            ]
        case .cardigan:
            shapes += [
                // 안에 받쳐 입은 흰 티 (V자) → 여밈선 → 단추
                .path("M-7.6,-43 L7.6,-43 L0,-30.4 Z", fill: white, width: 1.2),
                .line("M0,-30.4 L0,-14.8", width: 1.2, color: .topShade),
                ArtShape(.circle(center: MapPoint(2.8, -26.4), radius: 1.2), fill: white, stroke: .topShade, lineWidth: 0.8),
                ArtShape(.circle(center: MapPoint(2.8, -20.2), radius: 1.2), fill: white, stroke: .topShade, lineWidth: 0.8),
            ]
        }
        if isLead {
            shapes.append(ArtShape(.path(star5(MapPoint(7, -31), 4.6)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 1.3))
        }
        return shapes
    }

    /// 어깨가 원점, 아래로 늘어진 팔 (회전은 렌더러가 적용). 줄무늬 티만 반소매입니다.
    public static func arm(_ outfit: Outfit = .hoodie) -> [ArtShape] {
        let hand = ArtShape.circle(0, 16, 4.2, fill: .skin)
        switch outfit {
        case .stripes:
            return [
                .rect(-3.1, 3, 6.2, 12, r: 3.1, fill: .skin),
                .rect(-3.8, -2, 7.6, 10.6, r: 3.6, fill: .top),
                .line("M-2.7,5.4 L2.7,5.4", width: 1.4, color: .topLight),
                hand,
            ]
        default:
            return [
                .rect(-3.6, -2, 7.2, 17, r: 3.6, fill: .top),
                .line("M-2.5,11.3 L2.5,11.3", width: 1.3, color: .topShade),
                hand,
            ]
        }
    }

    /// 오른손에 드는 소품 (팔과 함께 회전)
    public static func handProp(_ prop: Prop?) -> [ArtShape] {
        switch prop {
        case .cup:
            return [
                .line("M4.5,13 q4.2,1 0,5.2", width: 1.5),
                .rect(-4.5, 11, 9, 9.4, r: 2.2, fill: .swatch(.white)),
                .rect(-4.5, 14, 9, 2.6, fill: .swatch(.peach), outline: false),
                ArtShape(.rect(MapRect(-4.5, 11, 9, 9.4), radius: 2.2), stroke: .swatch(.ink)),
            ]
        case .marker:
            return [
                .rect(-1.7, 12, 3.4, 12, r: 1.3, fill: .swatch(.alert), width: 1),
                .rect(-1.7, 12, 3.4, 3.4, r: 1.3, fill: .swatch(.ink), outline: false),
            ]
        case .drink:
            // 냉장고에서 꺼낸 캔 음료
            return [
                .rect(-4, 10, 8, 12, r: 2, fill: .swatch(.peach), width: 1.3),
                .rect(-4, 14, 8, 3.2, fill: .swatch(.white), outline: false),
                .line("M-2.4,11.4 L2.4,11.4", width: 1, color: .swatch(.metalDot)),
                ArtShape(.rect(MapRect(-4, 10, 8, 12), radius: 2), stroke: .swatch(.ink), lineWidth: 1.3),
            ]
        default:
            return []
        }
    }

    /// 제스처에 딸린 손 모양 (오른팔과 함께 회전). 엄지척은 팔이 옆으로 뻗을 때 위를 향하는 엄지를 그립니다.
    public static func handGesture(_ gesture: BodyGesture?) -> [ArtShape] {
        switch gesture {
        case .thumbsUp: [.rect(2.5, 13.6, 7.5, 4.6, r: 2.3, fill: .skin, width: 1.4)]
        default: []
        }
    }

    /// 몸 앞에 드는 소품 (원점: heldPropOrigin)
    public static func heldProp(_ prop: Prop?) -> [ArtShape] {
        switch prop {
        case .book:
            return [
                .rect(-12, -7.5, 24, 15, r: 2.2, fill: .swatch(.lavender)),
                .rect(-10, -5.6, 20, 11.2, r: 1.2, fill: .swatch(.white), outline: false),
                .line("M0,-5.6 L0,5.6", width: 1.1),
                .line("M-8,-2.6 L-3,-2.6 M-8,0.2 L-3.6,0.2 M-8,3 L-4.4,3 M3,-2.6 L8,-2.6 M3,0.2 L7,0.2", width: 0.9, color: .swatch(.plateInk), opacity: 0.7),
                // 책갈피 끈
                .path("M5.4,5.6 L5.4,10 L6.7,8.8 L8,10 L8,5.6 Z", fill: .swatch(.alert), width: 0.8),
            ]
        case .documents:
            return [
                .rect(-12, -6, 22, 14, r: 1.6, fill: .swatch(.white), width: 1.2),
                .rect(-9, -9, 22, 14, r: 1.6, fill: .swatch(.white), width: 1.2),
                .line("M-6,-5.2 L8,-5.2 M-6,-2.2 L6,-2.2 M-6,0.8 L8,0.8", width: 0.9, color: .swatch(.plateInk), opacity: 0.7),
                // 클립
                .line("M9.6,-10.4 L9.6,-6.2", width: 1.6, color: .swatch(.skyBlue)),
            ]
        default:
            return []
        }
    }

    // MARK: - 머리 (원점: headOrigin)

    public static let face: [ArtShape] = [.circle(0, 0, 21, fill: .skin)]

    /// 귀. 얼굴 원보다 먼저 그려 바깥쪽 반만 보입니다 (긴 머리·헤드폰·비니는 그 위를 덮습니다).
    public static let ears: [ArtShape] = [-1.0, 1.0].flatMap { side -> [ArtShape] in
        [
            .circle(side * 20.3, 5.2, 3.3, fill: .skin, width: 1.6),
            .line("M\(side * 21.3),4.1 Q\(side * 22.4),5.2 \(side * 21.3),6.4", width: 0.9, color: .skinShade),
        ]
    }

    public static func blush(_ expression: FacialExpression) -> [ArtShape] {
        let opacity = [.happy, .proud, .eager].contains(expression) ? 0.7 : 0.42
        return [
            .ellipse(-13.6, 9.2, 4.2, 2.6, fill: .swatch(.blush), opacity: opacity),
            .ellipse(13.6, 9.2, 4.2, 2.6, fill: .swatch(.blush), opacity: opacity),
        ]
    }

    // 머리 모양 5종: 0 단발(앞머리) · 1 삐죽 머리 · 2 긴 생머리 · 3 양갈래 똥머리 · 4 짧은 가르마(바보털)
    // 뒷머리의 윗부분은 앞머리 안쪽에 숨기고(선이 두 겹으로 보이지 않게), 옆과 아래로만 나옵니다.

    public static func hairBack(style: Int) -> [ArtShape] {
        switch abs(style) % 5 {
        case 0: [bobBack]
        case 1: [shortBack, .path("M-9,-22 Q-9.6,-27 -7,-30 Q-5.4,-26.6 -3,-25.6 Q-2,-29.6 1,-31.6 Q1.6,-27.6 4.6,-25.6 Q6,-28 9,-29 Q8.6,-25 10,-21.6 Z", fill: .hair)]
        case 2: [longBack, .line("M-22.6,9 L-23.6,26 M22.6,9 L23.6,26", width: 1, color: .hairShade)]
        case 3:
            [
                .circle(-16, -21.5, 7.6, fill: .hair), .circle(16, -21.5, 7.6, fill: .hair),
                .line("M-20.6,-25.4 Q-18.6,-27.8 -15.6,-27.6 M11.4,-25.4 Q13.4,-27.8 16.4,-27.6", width: 1.6, color: .hairShine),
                shortBack,
            ]
        default: [shortBack]
        }
    }

    public static func hairFront(style: Int) -> [ArtShape] {
        switch abs(style) % 5 {
        case 0, 3: [fringe, shine]
        case 1: [spikyFringe, shine]
        case 2:
            [
                // 귀 앞으로 내려온 옆머리 → 가르마 탄 앞머리 → 가르마 선
                .path("M-21.6,-1 C-22.8,5 -22.2,10 -20.2,14.5 C-19.2,9 -18.8,3 -17.4,-2.8 Z", fill: .hair),
                .path("M21.6,-1 C22.8,5 22.2,10 20.2,14.5 C19.2,9 18.8,3 17.4,-2.8 Z", fill: .hair),
                .path("M-21.6,-1 C-23,-18 -10,-25 1,-25 C12,-25 23,-18 21.6,-1 C14,-4 6,-9.5 -1,-16 C-5,-9 -13,-4 -21.6,-1 Z", fill: .hair),
                .line("M-1,-16 Q-2.8,-20 -2.2,-24", width: 1.1, color: .hairShade),
                shine,
            ]
        default:
            [
                // 바보털 → 반대쪽으로 가르마 탄 앞머리
                .path("M0.4,-23.4 C-1.2,-29.6 3,-34.6 9,-34 C6,-31.4 4.8,-28 5.6,-23.4 Z", fill: .hair),
                .path("M21.6,-1 C23,-18 10,-25 -1,-25 C-12,-25 -23,-18 -21.6,-1 C-14,-4 -6,-9.5 1,-16 C5,-9 13,-4 21.6,-1 Z", fill: .hair),
                .line("M1,-16 Q2.8,-20 2.2,-24", width: 1.1, color: .hairShade),
                shine,
            ]
        }
    }

    static let shortBack = ArtShape.circle(0, -3, 22.5, fill: .hair)
    static let bobBack = ArtShape.path(
        "M-21,-6 C-22,-18 -11,-24 0,-24 C11,-24 22,-18 21,-6 C23.6,-2 24.8,6 23.6,11 C22.8,15.6 19.6,17.6 16.6,17.2 C13.6,16.8 12.6,14 14,12 "
            + "L-14,12 C-12.6,14 -13.6,16.8 -16.6,17.2 C-19.6,17.6 -22.8,15.6 -23.6,11 C-24.8,6 -23.6,-2 -21,-6 Z", fill: .hair)
    static let longBack = ArtShape.path(
        "M-21,-6 C-22,-18 -11,-24 0,-24 C11,-24 22,-18 21,-6 C24,-1 24.6,8 25,16 L26.4,27 C26.4,31 22.6,33.2 18.6,31.6 "
            + "L-18.6,31.6 C-22.6,33.2 -26.4,31 -26.4,27 L-25,16 C-24.6,8 -24,-1 -21,-6 Z", fill: .hair)
    /// 둥근 술 세 갈래가 내려온 앞머리
    static let fringe = ArtShape.path(
        "M-21.6,-1 C-23,-18 -11,-25 0,-25 C11,-25 23,-18 21.6,-1 Q20.4,-6.4 15,-8.6 Q10.6,-3.4 6,-8.6 Q0.4,-3 -5,-8.6 Q-9.8,-3.4 -14.4,-8.6 "
            + "Q-19.6,-7 -21.6,-1 Z", fill: .hair)
    /// 한쪽으로 쓸린 뾰족한 앞머리
    static let spikyFringe = ArtShape.path(
        "M-21.6,-1.5 C-23,-18 -11,-25 0,-25 C11,-25 23,-18 21.6,-1.5 Q19.6,-6.6 16.6,-9.6 Q15.6,-6 13,-4.6 Q12.6,-9 9.6,-12 Q8,-7.6 4.6,-6 "
            + "Q4,-10 1,-13 Q-1,-9 -4.6,-7.6 Q-5,-11 -8,-13 Q-9.6,-8.6 -13,-6.6 Q-13.6,-9 -16,-10.6 Q-19.6,-7 -21.6,-1.5 Z", fill: .hair)
    /// 정수리 왼쪽의 윤기 (짧은 호 + 점)
    static let shine = ArtShape.line("M-14,-15.4 Q-9.4,-20.6 -3,-21.4 M0.8,-21.5 L1.6,-21.5", width: 2, color: .hairShine)

    public static func accessory(_ accessory: Accessory?) -> [ArtShape] {
        switch accessory {
        case .glasses:
            let ex = eyeX, ey = eyeLine
            return [
                .circle(-ex, ey, 5.5, fill: .swatch(.white), outline: false, opacity: 0.2),
                .circle(ex, ey, 5.5, fill: .swatch(.white), outline: false, opacity: 0.2),
                ArtShape(.circle(center: MapPoint(-ex, ey), radius: 5.7), stroke: .swatch(.ink), lineWidth: 1.5),
                ArtShape(.circle(center: MapPoint(ex, ey), radius: 5.7), stroke: .swatch(.ink), lineWidth: 1.5),
                .line("M-2.8,\(ey - 0.6) Q0,\(ey - 2) 2.8,\(ey - 0.6)", width: 1.5),
                .line("M-14.2,\(ey - 1) L-19.6,\(ey - 2) M14.2,\(ey - 1) L19.6,\(ey - 2)", width: 1.3),
            ]
        case .headphones:
            let band = "M-23,2 C-24,-31 24,-31 23,2"
            return [
                .line(band, width: 5.6),
                .line(band, width: 3, color: .color(ArtColor(0x8F84C6))),
                .rect(-27.5, -4.5, 8, 13.5, r: 3.6, fill: .swatch(.lavender)),
                .rect(19.5, -4.5, 8, 13.5, r: 3.6, fill: .swatch(.lavender)),
                .line("M-25.4,-1.6 L-25.4,2 M25.4,-1.6 L25.4,2", width: 1.3, color: .swatch(.white)),
            ]
        case .beanie:
            let knit = Paint.color(ArtColor(0xD98A70))
            return [
                .path("M-22,-7 C-22,-31 22,-31 22,-7 Z", fill: .swatch(.peach)),
                .line("M-11,-12 Q-10,-20 -5.4,-24 M0,-12 L0,-25 M11,-12 Q10,-20 5.4,-24", width: 1, color: knit, opacity: 0.55),
                .rect(-23, -11.5, 46, 7.6, r: 3.8, fill: .color(ArtColor(0xEE9F84))),
                .line("M-16.5,-9.6 L-16.5,-5.8 M-10,-9.6 L-10,-5.8 M-3.4,-9.6 L-3.4,-5.8 M3.4,-9.6 L3.4,-5.8 M10,-9.6 L10,-5.8 M16.5,-9.6 L16.5,-5.8", width: 1, color: knit),
                .circle(0, -29.4, 4.8, fill: .swatch(.white)),
                .line("M-1.8,-31 Q-0.4,-32.2 1.2,-31.6", width: 0.9, color: .swatch(.metal)),
            ]
        case .ribbon:
            let dark = Paint.color(ArtColor(0xE77F98))
            return [
                // 리본 고리 둘 → 매듭 → 주름
                .path("M14,-19.5 C11,-26 4.4,-25 5,-19.5 C4.4,-14 11,-13 14,-19.5 Z", fill: .swatch(.pink)),
                .path("M14,-19.5 C17,-26 23.6,-25 23,-19.5 C23.6,-14 17,-13 14,-19.5 Z", fill: .swatch(.pink)),
                .line("M8,-19.5 L10.6,-19.5 M20,-19.5 L17.4,-19.5", width: 1, color: dark),
                .circle(14, -19.5, 2.4, fill: dark, width: 1.4),
            ]
        case .sprout:
            let stem = Paint.color(ArtColor(0x5FA77F))
            return [
                .line("M0,-24 C0,-30 1,-33 0,-36", width: 2, color: stem),
                .path("M0,-36 C-3,-41.4 -9.6,-41 -10.4,-37 C-7,-34.4 -2.6,-34.4 0,-36 Z", fill: .swatch(.mint), width: 1.5),
                .path("M0,-36.4 C2,-42.4 8.6,-43.4 10.4,-39.6 C7.6,-36.2 3,-35.2 0,-36.4 Z", fill: .swatch(.mint), width: 1.5),
                .line("M-1.6,-36.6 L-7,-38 M1.6,-37.2 L7,-39.6", width: 0.9, color: stem),
            ]
        case .none:
            return []
        }
    }

    // MARK: - 표정 (설계서 §9.3 표정 10종)

    /// 동그란 눈: 잉크 눈동자 + 오른쪽 위 큰 반짝임 + 왼쪽 아래 작은 반짝임
    static func dotEye(_ x: Double, _ y: Double = eyeLine, rx: Double = 2.9, ry: Double = 3.6) -> [ArtShape] {
        [
            .ellipse(x, y, rx, ry, fill: .swatch(.ink)),
            .circle(x + rx * 0.36, y - ry * 0.36, rx * 0.38, fill: .swatch(.white), outline: false),
            .circle(x - rx * 0.36, y + ry * 0.42, rx * 0.17, fill: .swatch(.white), outline: false, opacity: 0.85),
        ]
    }

    /// 눈 두 개 (왼쪽·오른쪽 같은 모양)
    static func bothEyes(_ eye: (Double) -> [ArtShape]) -> [ArtShape] { eye(-eyeX) + eye(eyeX) }

    static let worried: [ArtShape] = [.line("M-11.6,-3.6 L-5.6,-6.2", width: 1.5), .line("M5.6,-6.2 L11.6,-3.6", width: 1.5)]
    static let raisedBrows: [ArtShape] = [.line("M-11.6,-5.4 Q-8.5,-8 -5.4,-5.6", width: 1.5), .line("M5.4,-5.6 Q8.5,-8 11.6,-5.4", width: 1.5)]

    public static func eyes(_ expression: FacialExpression) -> [ArtShape] {
        let ex = eyeX, ey = eyeLine
        switch expression {
        case .neutral, .troubled: return bothEyes { dotEye($0) }
        case .happy:
            // 웃어서 감긴 눈 (⌒)
            return [.line("M\(-ex - 3.2),\(ey + 1.6) Q\(-ex),\(ey - 3) \(-ex + 3.2),\(ey + 1.6)", width: 2.2), .line("M\(ex - 3.2),\(ey + 1.6) Q\(ex),\(ey - 3) \(ex + 3.2),\(ey + 1.6)", width: 2.2)]
        case .focus:
            return bothEyes { [.ellipse($0, ey + 0.6, 2.8, 2.5, fill: .swatch(.ink)), .circle($0 + 1, ey - 0.2, 0.9, fill: .swatch(.white), outline: false)] }
        case .think:
            // 위를 올려다보는 눈
            return dotEye(-ex + 1.6, ey - 1.4, rx: 2.6, ry: 3.2) + dotEye(ex + 1.6, ey - 1.4, rx: 2.6, ry: 3.2)
        case .surprised:
            return bothEyes { [.circle($0, ey, 4, fill: .swatch(.white), width: 1.3), .circle($0, ey + 0.3, 1.9, fill: .swatch(.ink), outline: false)] }
        case .sleepy:
            // 졸려서 감긴 눈 (‿)
            return [.line("M\(-ex - 3),\(ey) Q\(-ex),\(ey + 3) \(-ex + 3),\(ey)", width: 2), .line("M\(ex - 3),\(ey) Q\(ex),\(ey + 3) \(ex + 3),\(ey)", width: 2)]
        case .proud:
            return bothEyes { [ArtShape(.path(star4(MapPoint($0, ey), 4.4)), fill: .swatch(.ink))] }
        case .sad:
            return bothEyes { dotEye($0, ey + 0.4, rx: 2.5, ry: 3) }
        case .eager:
            return bothEyes {
                [
                    .circle($0, ey, 3.8, fill: .swatch(.ink), outline: false),
                    .circle($0 + 1.4, ey - 1.4, 1.45, fill: .swatch(.white), outline: false),
                    .circle($0 - 1.4, ey + 1.6, 0.75, fill: .swatch(.white), outline: false),
                ]
            }
        }
    }

    /// 눈을 감은 표정은 깜빡이지 않습니다
    public static func blinks(_ expression: FacialExpression) -> Bool {
        ![.happy, .sleepy, .proud].contains(expression)
    }

    public static func brows(_ expression: FacialExpression) -> [ArtShape] {
        switch expression {
        case .focus: [.line("M-12,-3.2 L-5.4,-1.8", width: 1.7), .line("M5.4,-1.8 L12,-3.2", width: 1.7)]
        case .think: [.line("M-10.4,-5 Q-7.4,-7 -4.4,-5.6", width: 1.5), .line("M7,-7.4 Q10,-9.6 13,-7.8", width: 1.5)]
        case .surprised, .eager: raisedBrows
        case .troubled, .sad: worried
        default: []
        }
    }

    static let tongue = ArtColor(0xF08FA0)

    /// 활짝 웃는 입 (반달 + 혀)
    static func smile(_ halfWidth: Double, top: Double = 8.6, depth: Double) -> [ArtShape] {
        let w = halfWidth
        return [
            .path("M\(-w),\(top) Q0,\(top + depth * 2) \(w),\(top) Z", fill: .swatch(.mouth), width: 1.6),
            .ellipse(0, top + depth * 0.72, w * 0.42, depth * 0.24, fill: .color(tongue)),
        ]
    }

    public static func mouth(_ expression: FacialExpression) -> [ArtShape] {
        switch expression {
        case .neutral: [.line("M-3.2,10.6 Q0,13.4 3.2,10.6", width: 1.8)]
        case .happy: smile(5.6, depth: 3.8)
        case .focus: [.line("M-2.6,11.6 L2.6,11.6", width: 1.8)]
        case .think: [ArtShape(.circle(center: MapPoint(3, 11.6), radius: 1.7), stroke: .swatch(.ink), lineWidth: 1.6)]
        case .surprised: [.ellipse(0, 12, 2.5, 3.1, fill: .swatch(.mouth), outline: true, width: 1.6)]
        case .troubled: [.line("M-4.5,12 q1.5,-2 3,0 t3,0", width: 1.7)]
        case .sleepy: [.ellipse(0, 11.6, 1.7, 1.3, fill: .swatch(.ink))]
        case .proud: smile(6.2, depth: 3.6)
        case .sad: [.line("M-3.4,13.6 Q0,10.6 3.4,13.6", width: 1.8)]
        case .eager: smile(4.4, top: 9, depth: 3.2)
        }
    }

    /// 표정에 딸린 효과 (땀방울, 반짝이, 눈물)
    public static func effects(_ expression: FacialExpression) -> [ArtShape] {
        switch expression {
        case .troubled: [.path("M18,-14 q-4.5,6.5 0,8.5 q4.5,-2 0,-8.5 Z", fill: .swatch(.drop), width: 1.4)]
        case .proud: [ArtShape(.path(star4(MapPoint(22, -20), 5.5)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 1.3)]
        case .sad:
            [
                .path("M\(-eyeX),7.4 q-2.4,3.8 0,5 q2.4,-1.2 0,-5 Z", fill: .swatch(.drop), width: 1),
                .path("M\(eyeX),7.4 q-2.4,3.8 0,5 q2.4,-1.2 0,-5 Z", fill: .swatch(.drop), width: 1),
            ]
        default: []
        }
    }

    // MARK: - 초상 (목록·카드용)

    /// 얼굴과 어깨만 담은 초상. 좌표 원점은 머리 중심이고, `portraitFrame` 안에 들어옵니다.
    /// 사무실 캐릭터와 같은 부위 데이터를 쓰므로 목록에서 본 얼굴을 사무실에서 그대로 찾을 수 있습니다.
    public static func portrait(_ appearance: Appearance, isLead: Bool, expression: FacialExpression = .happy) -> [ArtShape] {
        // 몸과 팔은 발 기준 좌표 → 머리 중심 기준으로 옮깁니다
        let toHead = MapPoint(-headOrigin.x, -headOrigin.y)
        let outfit = outfit(for: appearance)
        let arms = [leftShoulder, rightShoulder].flatMap { shoulder in
            arm(outfit).map { $0.transformed(offset: MapPoint(shoulder.x + toHead.x, shoulder.y + toHead.y)) }
        }
        return hairBack(style: appearance.hairStyle)
            + body(isLead: isLead, outfit: outfit).map { $0.transformed(offset: toHead) }
            + arms
            + ears + face
            + eyes(expression)
            + blush(expression) + mouth(expression) + hairFront(style: appearance.hairStyle)
            + brows(expression) + accessory(appearance.accessory)
    }

    /// 초상을 담는 정사각형 (머리 위 새싹부터 가슴의 별 배지까지)
    public static let portraitFrame = MapRect(-42, -45, 84, 84)

    // MARK: - 도형 도우미

    static func star4(_ c: MapPoint, _ r: Double) -> [PathCommand] {
        [
            .move(MapPoint(c.x, c.y - r)), .quad(control: c, to: MapPoint(c.x + r, c.y)), .quad(control: c, to: MapPoint(c.x, c.y + r)),
            .quad(control: c, to: MapPoint(c.x - r, c.y)), .quad(control: c, to: MapPoint(c.x, c.y - r)), .close,
        ]
    }

    static func star5(_ c: MapPoint, _ r: Double) -> [PathCommand] {
        var commands: [PathCommand] = []
        for i in 0..<10 {
            let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
            let radius = i % 2 == 1 ? r * 0.45 : r
            let point = MapPoint(c.x + radius * cos(angle), c.y + radius * sin(angle))
            commands.append(i == 0 ? .move(point) : .line(point))
        }
        commands.append(.close)
        return commands
    }
}
