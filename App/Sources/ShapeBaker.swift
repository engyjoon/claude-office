import AppKit
import OfficeStage
import SpriteKit

/// 도형(ArtShape) 묶음을 CoreGraphics로 비트맵 한 장에 그려 SpriteKit 텍스처로 만듭니다 (M6(1), 설계서 §8.3).
///
/// SKShapeNode는 매 프레임 선을 다시 나누고(테셀레이션) 경계 상자를 구하려고 선 경로를 다시 만들어서,
/// 사무실(가구·캐릭터·말풍선 도형 수천 개)을 30fps로 그리면 CPU를 40% 넘게 썼습니다. 그림은 바뀔 때만 굽고,
/// 매 프레임은 텍스처 사각형만 그립니다.
///
/// - 좌표는 노드 안 좌표(그림 데이터 y를 뒤집은 `(x, -y)`)입니다. 기준점(0,0)이 그대로 노드 원점이라 팔·머리 축 회전이 같습니다.
/// - 화면 배율(레티나 2배)로 굽고, 채우기는 SKShapeNode와 같은 even-odd 규칙, 선은 둥근 이음·끝입니다.
/// - 투명도가 있는 도형은 채우기와 선을 한 덩어리로 투명하게 그립니다 (SVG 스냅숏의 opacity와 같음).
/// - 같은 도형·색이면 텍스처를 다시 씁니다 (같은 모습의 직원, 다시 만든 가구).
enum ShapeBaker {
    /// 굽는 배율: 연결된 화면 중 가장 높은 배율 (레티나 2, 일반 모니터 1).
    /// 1배율 화면에 2배로 구우면 텍스처 메모리만 4배가 됩니다 (M6(1) 측정: QHD 1배율 화면). 화면 구성이 바뀌면 다시 정합니다.
    private(set) static var scale: CGFloat = currentScreenScale()
    /// 배율이 바뀔 때마다 1씩 늘어남 (장면이 가구를 다시 굽는 신호)
    private(set) static var generation = 0

    private static func currentScreenScale() -> CGFloat {
        max(1, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
    }

    /// 화면 구성이 바뀌었을 때 부릅니다: 배율이 달라졌으면 캐시를 비우고 `generation`을 올립니다
    static func screensChanged() {
        let next = currentScreenScale()
        guard next != scale else { return }
        scale = next
        cache.removeAll()
        generation += 1
    }

    private struct Key: Hashable {
        let shapes: [ArtShape]
        let colors: CharacterArt.Colors?
        let clip: [Double]?
    }

    private struct Baked {
        let texture: SKTexture
        /// 노드 안 좌표에서 텍스처가 덮는 영역 (포인트)
        let frame: CGRect
    }

    private static var cache: [Key: Baked] = [:]
    /// 캐시 상한 (넘으면 비움). 말풍선 바탕처럼 폭이 제각각인 그림이 쌓이지 않게 작게 둡니다.
    private static let cacheLimit = 300
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 이보다 픽셀이 많은 층은 GPU에서 굽습니다 (약 1000×1000)
    private static let largeTexturePixels = 1_000_000
    /// GPU 굽기용 화면 밖 뷰 (창에 붙지 않아 배율 1로 그리므로 노드를 `scale`배 키워서 그림)
    /// 멈춰 둡니다: 멈추지 않은 SKView는 장면이 없어도 디스플레이 링크가 vsync마다 메인 스레드를 깨움 (`texture(from:)`은 멈춰도 됨)
    private static let offscreenView: SKView = {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        view.isPaused = true
        return view
    }()

    private static func renderOnGPU(_ shapes: [ArtShape], colors: CharacterArt.Colors?, frame: CGRect) -> SKTexture? {
        let wrapper = SKNode()
        wrapper.setScale(scale)
        wrapper.addChild(ArtNodes.unbakedNode(for: shapes, colors: colors, transform: ArtNodes.local))
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        return offscreenView.texture(from: wrapper, crop: crop)
    }

    /// 지금 캐시에 든 텍스처의 픽셀 바이트 합 (디버그 계측, RGBA 4바이트)
    static var cachedBytes: Int {
        cache.values.reduce(0) { $0 + Int($1.frame.width * scale) * Int($1.frame.height * scale) * 4 }
    }
    /// 마지막으로 GPU에서 구운 큰 층들의 바이트 (캐시하지 않음, 디버그 계측)
    static var largeBytes: [String: Int] = [:]

    /// 지금 캐시에 든 텍스처 수 (디버그 계측)
    static var cachedCount: Int { cache.count }

    /// 도형 묶음 → 스프라이트 하나 (그릴 것이 없으면 빈 노드)
    /// - Parameter clip: 이 영역(노드 안 좌표) 밖은 굽지 않습니다. 화면에 보이는 부분만 굽는 가구용 (미니는 지도 전체 중 한 행 띠만 보임).
    static func node(for shapes: [ArtShape], colors: CharacterArt.Colors?, clip: CGRect? = nil) -> SKNode {
        guard let baked = bake(shapes, colors: colors, clip: clip) else { return SKNode() }
        let sprite = SKSpriteNode(texture: baked.texture, size: baked.frame.size)
        sprite.anchorPoint = CGPoint(x: -baked.frame.minX / baked.frame.width, y: -baked.frame.minY / baked.frame.height)
        return sprite
    }

    private static func bake(_ shapes: [ArtShape], colors: CharacterArt.Colors?, clip: CGRect?) -> Baked? {
        let key = Key(shapes: shapes, colors: colors, clip: clip.map { [$0.minX, $0.minY, $0.width, $0.height] })
        if let cached = cache[key] { return cached }

        let local: (MapPoint) -> CGPoint = { CGPoint(x: $0.x, y: -$0.y) }
        var items: [(shape: ArtShape, path: CGPath)] = []
        var bounds = CGRect.null
        for shape in shapes {
            if case .text = shape.geometry { continue }
            let path = ArtNodes.path(shape.geometry, transform: local)
            guard !path.isEmpty else { continue }
            var box = path.boundingBoxOfPath
            if shape.stroke != nil { box = box.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2) }
            bounds = bounds.union(box)
            items.append((shape, path))
        }
        guard !items.isEmpty, !bounds.isNull, bounds.width > 0 || bounds.height > 0 else { return nil }
        // 안티에일리어싱 가장자리 1pt + 정수 픽셀에 맞춤, 보이는 영역만
        var frame = bounds.insetBy(dx: -1, dy: -1).integral
        if let clip {
            frame = frame.intersection(clip.integral)
            guard !frame.isNull, frame.width >= 1, frame.height >= 1 else { return nil }
        }
        let width = Int((frame.width * scale).rounded(.up)), height = Int((frame.height * scale).rounded(.up))
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        // 바닥·벽처럼 큰 층은 GPU에서 한 번 그려 GPU 텍스처로만 둡니다 (CGImage로 만들면 CPU 사본이 텍스처마다 남아 메모리가 50MB 넘게 늘었음).
        // 가구를 다시 만들 때만 그리므로(창 크기·행이 바뀔 때) 동기 렌더링 비용(수십 ms)은 괜찮습니다. 캐시하지 않습니다.
        if width * height > largeTexturePixels, let texture = renderOnGPU(items.map(\.shape), colors: colors, frame: frame) {
            largeBytes["\(Int(frame.width))x\(Int(frame.height))"] = width * height * 4
            return Baked(texture: texture, frame: frame)
        }
        guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        for (shape, path) in items {
            let grouped = shape.opacity < 1
            if grouped {
                context.setAlpha(shape.opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            if let fill = shape.fill {
                context.addPath(path)
                context.setFillColor(ArtNodes.color(fill, colors).cgColor)
                context.fillPath(using: .evenOdd)
            }
            if let stroke = shape.stroke, shape.lineWidth > 0 {
                context.addPath(path)
                context.setStrokeColor(ArtNodes.color(stroke, colors).cgColor)
                context.setLineWidth(shape.lineWidth)
                context.setLineDash(phase: 0, lengths: shape.dash > 0 ? [shape.dash, shape.dash] : [])
                context.strokePath()
            }
            if grouped {
                context.endTransparencyLayer()
                context.setAlpha(1)
            }
        }
        guard let image = context.makeImage() else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        let baked = Baked(texture: texture, frame: frame)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = baked
        return baked
    }
}
