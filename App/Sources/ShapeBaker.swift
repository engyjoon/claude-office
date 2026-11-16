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
/// - 장면이 정한 배율(창이 놓인 화면의 배율, 레티나 2배)로 굽고, 채우기는 SKShapeNode와 같은 even-odd 규칙, 선은 둥근 이음·끝입니다.
/// - 투명도가 있는 도형은 채우기와 선을 한 덩어리로 투명하게 그립니다 (SVG 스냅숏의 opacity와 같음).
/// - 같은 도형·색·배율이면 텍스처를 다시 씁니다 (같은 모습의 직원, 다시 만든 가구). 캐시는 장 수·픽셀 합 상한에서
///   가장 오래 안 쓴 것부터 버리고(`TextureCacheLedger`), 어느 장면도 쓰지 않게 된 배율의 텍스처는 바로 버립니다 (개선 10).
enum ShapeBaker {
    /// 창에 붙기 전에 쓰는 배율: 연결된 화면 중 가장 높은 배율 (레티나 2, 일반 모니터 1). 화면 구성이 바뀌면 다시 정합니다.
    /// 장면은 창에 붙으면 그 창의 `backingScaleFactor`로 굽습니다 (`OfficeScene.screenScale`, 개선 10).
    private(set) static var fallbackScale: CGFloat = currentScreenScale()

    /// 층마다 굽는 배율 (개선 10). 기본은 모든 층을 화면 배율로. 측정할 때만 환경 변수 `CLAUDE_OFFICE_BAKE_SCALE`로 바꿉니다.
    static let policy = BakeScalePolicy.parse(ProcessInfo.processInfo.environment[BakeScalePolicy.environmentKey])

    private static func currentScreenScale() -> CGFloat {
        max(1, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
    }

    /// 화면 구성이 바뀌었을 때 부릅니다: 창에 붙기 전에 쓸 배율만 다시 정합니다
    /// (창에 붙은 장면은 다음 장에서 창의 배율이 바뀐 것을 보고 스스로 다시 굽습니다)
    static func screensChanged() {
        fallbackScale = currentScreenScale()
    }

    /// 장면마다 지금 쓰는 배율들. 어느 장면도 쓰지 않는 배율의 텍스처는 캐시에서 버립니다.
    private static var scalesInUse: [ObjectIdentifier: Set<Double>] = [:]

    /// 장면이 굽는 배율이 바뀌었음 (처음 정할 때 포함). 아무 장면도 쓰지 않게 된 배율의 텍스처를 캐시에서 버립니다.
    static func use(scales: Set<Double>, by owner: AnyObject) {
        scalesInUse[ObjectIdentifier(owner)] = scales
        let keep = scalesInUse.values.reduce(into: Set<Double>()) { $0.formUnion($1) }
        for key in ledger.evict(keepingScales: keep) { cache[key] = nil }
        largeBytes = largeBytes.filter { entry in keep.contains { entry.key.hasSuffix("@\($0)x") } }
    }

    /// 캐시를 비웁니다 (화면의 노드가 든 텍스처는 그대로). 사무실 창이 닫혀 장면이 뷰에서 떨어질 때 부릅니다.
    static func purge() {
        for key in ledger.evict(keepingScales: []) { cache[key] = nil }
        cache.removeAll()
    }

    private struct Key: Hashable {
        let shapes: [ArtShape]
        let colors: CharacterArt.Colors?
        let clip: [Double]?
        /// 굽는 배율 (같은 그림도 배율이 다르면 다른 텍스처)
        let scale: Double
    }

    private struct Baked {
        let texture: SKTexture
        /// 노드 안 좌표에서 텍스처가 덮는 영역 (포인트)
        let frame: CGRect
    }

    private static var cache: [Key: Baked] = [:]
    /// 무엇을 버릴지 (개선 10): 장 수·픽셀 합이 넘으면 가장 오래 안 쓴 것부터. 예전에는 300장에서 통째로 비웠습니다.
    private static var ledger = TextureCacheLedger<Key>()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 이보다 픽셀이 많은 층(바닥·벽 바탕, 약 1000×1000)은 캐시하지 않습니다. 가구를 다시 만들 때만 굽고 같은 그림을 다시 쓸 일이 드물어,
    /// 담으면 작은 텍스처(캐릭터 부위·롤러 그림)만 밀려납니다.
    private static let largeTexturePixels = 1_000_000
    /// 이보다 픽셀이 많은 층을 화면 밖 SKView로(GPU) 굽기. 기본은 꺼짐(모두 CoreGraphics), 측정 실행에서만 `CLAUDE_OFFICE_GPU_BAKE_PIXELS`로 켭니다.
    ///
    /// 개선 10 실측(5K 2배율, M3): 예전처럼 100만 픽셀이 넘는 층을 GPU로 구우면 큰 층 텍스처 약 33MB에 그래픽 메모리가 약 113MB
    /// 더 잡혔고(화면 밖 SKView 렌더러의 몫, 내려가지 않음), CoreGraphics로 구우면 텍스처는 GPU 메모리(IOAccelerator)에만 남고
    /// CPU 사본(CG image)은 0.1MB였습니다. 1배율 화면에서는 바탕이 100만 픽셀 아래라 예전에도 늘 CoreGraphics였습니다.
    private static let gpuBakePixels = PerfLaunch.gpuBakePixels
    /// GPU 굽기용 화면 밖 뷰 (창에 붙지 않아 배율 1로 그리므로 노드를 굽는 배율만큼 키워서 그림). `gpuBakePixels`를 줄 때만 만듭니다.
    /// 멈춰 둡니다: 멈추지 않은 SKView는 장면이 없어도 디스플레이 링크가 vsync마다 메인 스레드를 깨움 (`texture(from:)`은 멈춰도 됨)
    private static let offscreenView: SKView = {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        view.isPaused = true
        return view
    }()

    private static func renderOnGPU(_ shapes: [ArtShape], colors: CharacterArt.Colors?, frame: CGRect, scale: CGFloat) -> SKTexture? {
        let wrapper = SKNode()
        wrapper.setScale(scale)
        wrapper.addChild(ArtNodes.unbakedNode(for: shapes, colors: colors, transform: ArtNodes.local))
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        return offscreenView.texture(from: wrapper, crop: crop)
    }

    /// 지금 캐시에 든 텍스처의 픽셀 바이트 합 (디버그 계측, RGBA 4바이트, 실제 배율)
    static var cachedBytes: Int { ledger.totalPixels * 4 }
    /// 마지막으로 GPU에서 구운 큰 층들의 바이트 ("폭x높이@배율x", 캐시하지 않음, 디버그 계측)
    private(set) static var largeBytes: [String: Int] = [:]

    /// 지금 캐시에 든 텍스처 수 (디버그 계측)
    static var cachedCount: Int { cache.count }

    /// 장면들이 지금 쓰는 배율 (디버그 계측)
    static var scalesDescription: String {
        let all = scalesInUse.values.reduce(into: Set<Double>()) { $0.formUnion($1) }
        return all.isEmpty ? "\(fallbackScale)" : all.sorted().map { "\($0)" }.joined(separator: ",")
    }

    /// 도형 묶음 → 스프라이트 하나 (그릴 것이 없으면 빈 노드)
    /// - Parameter clip: 이 영역(노드 안 좌표) 밖은 굽지 않습니다. 화면에 보이는 부분만 굽는 가구용 (미니는 지도 전체 중 한 행 띠만 보임).
    /// - Parameter scale: 굽는 배율. 장면이 창의 배율과 층(`BakeLayer`)으로 정해 넘깁니다. 스프라이트 크기는 포인트라 배율과 무관합니다.
    static func node(for shapes: [ArtShape], colors: CharacterArt.Colors?, clip: CGRect? = nil, scale: CGFloat) -> SKNode {
        guard let baked = bake(shapes, colors: colors, clip: clip, scale: max(scale, 0.5)) else { return SKNode() }
        let sprite = SKSpriteNode(texture: baked.texture, size: baked.frame.size)
        sprite.anchorPoint = CGPoint(x: -baked.frame.minX / baked.frame.width, y: -baked.frame.minY / baked.frame.height)
        return sprite
    }

    private static func bake(_ shapes: [ArtShape], colors: CharacterArt.Colors?, clip: CGRect?, scale: CGFloat) -> Baked? {
        let key = Key(shapes: shapes, colors: colors, clip: clip.map { [$0.minX, $0.minY, $0.width, $0.height] }, scale: Double(scale))
        if let cached = cache[key] {
            ledger.touch(key)
            return cached
        }

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
        // 바닥·벽처럼 큰 층은 캐시하지 않습니다. 가구를 다시 만들 때만 그리므로(창 크기·행·명패·조명이 바뀔 때) 동기 굽기 비용은
        // 계측(`bake.large ms`)으로 봅니다.
        let isLarge = width * height > largeTexturePixels
        let started = isLarge ? Date() : nil
        defer {
            if let started {
                largeBytes["\(Int(frame.width))x\(Int(frame.height))@\(Double(scale))x"] = width * height * 4
                let ms = Date().timeIntervalSince(started) * 1000
                MainActor.assumeIsolated { PerfProbe.shared?.measured("bake.large", ms: ms) }  // 굽기는 늘 메인 스레드
            }
        }
        if let gpuBakePixels, width * height > gpuBakePixels,
            let texture = renderOnGPU(items.map(\.shape), colors: colors, frame: frame, scale: scale)
        {
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
                // 투명도 층은 잘린 영역만큼 버퍼를 만듭니다. 도형 경계(+ 선 굵기·안티에일리어싱 1pt)로 잘라 두면 결과 픽셀은 같고,
                // 밤 바탕(반투명 도형 55개, 2배율 350만 픽셀)이 622 → 12ms로 줄었습니다 (개선 10, 디버그 빌드 측정).
                context.saveGState()
                context.clip(to: path.boundingBoxOfPath.insetBy(dx: -shape.lineWidth - 1, dy: -shape.lineWidth - 1))
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
                context.restoreGState()
            }
        }
        guard let image = context.makeImage() else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        let baked = Baked(texture: texture, frame: frame)
        if isLarge { return baked }
        let (stored, evicted) = ledger.insert(key, pixels: width * height, scale: Double(scale))
        for old in evicted { cache[old] = nil }
        if stored { cache[key] = baked }
        return baked
    }
}
