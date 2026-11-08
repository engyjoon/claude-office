import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

@Suite("그리기 빈도 (M6(1), 설계서 §8.3)")
struct RenderPacerTests {
    @Test("안 보이면 멈춤, 빠른 움직임·훅 직후 30fps, 타이핑만 10fps, 쉬는 중 6fps, 20초 넘게 조용하면 3fps")
    func pace() {
        #expect(RenderPacer.pace(visible: false, motion: .fast, settling: true) == .paused)
        #expect(RenderPacer.pace(visible: true, motion: .fast, settling: false) == .active)
        #expect(RenderPacer.pace(visible: true, motion: .still, settling: true) == .active)
        #expect(RenderPacer.pace(visible: true, motion: .busy, settling: false, quietFor: 100) == .working)
        #expect(RenderPacer.pace(visible: true, motion: .still, settling: false) == .ambient)
        #expect(RenderPacer.pace(visible: true, motion: .still, settling: false, quietFor: 19) == .ambient)
        #expect(RenderPacer.pace(visible: true, motion: .still, settling: false, quietFor: 20) == .calm)
        #expect(RenderPacer.pace(visible: false, motion: .still, settling: false, quietFor: 100) == .paused)
        #expect(RenderPace.paused.framesPerSecond == 0)
        #expect(RenderPace.calm.framesPerSecond == 3)
        #expect(RenderPace.ambient.framesPerSecond == 6)
        #expect(RenderPace.working.framesPerSecond == 10)
        #expect(RenderPace.active.framesPerSecond == 30)
        #expect(RenderPace.calm < .ambient && .ambient < .working && .working < .active)
    }

    @Test("모델 타이머: 보이는 장면 중 가장 빠른 빈도, 다 안 보이면 4Hz")
    func tickInterval() {
        #expect(RenderPacer.tickInterval(for: [.paused, .paused]) == 0.25)
        #expect(RenderPacer.tickInterval(for: []) == 0.25)
        #expect(abs(RenderPacer.tickInterval(for: [.ambient, .paused]) - 1.0 / 6) < 1e-9)
        #expect(abs(RenderPacer.tickInterval(for: [.ambient, .active]) - 1.0 / 30) < 1e-9)
        #expect(abs(RenderPacer.tickInterval(for: [.calm, .paused]) - 1.0 / 3) < 1e-9)
    }

    @Test("느린 타이머의 dt는 0.1초 조각으로 나누고, 오래 멈췄다 깨면 0.5초까지만")
    func steps() {
        #expect(RenderPacer.steps(dt: 0.25) == [0.1, 0.1, 0.25 - 0.2].map { $0 })
        #expect(RenderPacer.steps(dt: 1.0 / 30) == [1.0 / 30])
        #expect(RenderPacer.steps(dt: 0).isEmpty)
        #expect(RenderPacer.steps(dt: -1).isEmpty)
        #expect(abs(RenderPacer.steps(dt: 30).reduce(0, +) - 0.5) < 1e-9)
    }

    @Test("출근해 걸을 때는 빠름, 자리에 앉아 쉬면 잔잔함, 자리에서 타이핑하면 일하는 중")
    func lively() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        #expect(RenderPacer.motion(h.stage) == .fast)
        h.run(until: 12)
        let seated = try! #require(h.actor("lead-1"))
        #expect(seated.seated)
        #expect(RenderPacer.motion(h.stage) == .still, "앉아 쉬는 중: \(seated.pose), 제스처 \(String(describing: seated.gesture))")
        #expect(!RenderPacer.isLively(h.stage))

        h.hook(hook("UserPromptSubmit", #""prompt":"고쳐 줘""#), at: 13)
        h.hook(tool("PreToolUse", "Edit", "t1", #"{"file_path":"/w/a-sdn-portal/a.swift"}"#), at: 14)
        h.run(until: 18)
        // 자리에서 타이핑만: 일하는 중 (10fps)
        #expect(h.actor("lead-1")?.pose == .typing)
        #expect(RenderPacer.motion(h.stage) == .busy)
        #expect(RenderPacer.isLively(h.stage))
    }

    @Test("쉬는 자세(숨쉬기·졸기·안마·컵)는 빠른 자세가 아님")
    func fastPoses() {
        #expect(RenderPacer.isFastPose(.typing))
        #expect(RenderPacer.isFastPose(.raisingHand))
        for pose in [Pose.standing, .sitting, .sleeping, .massage, .holdingCup, .watching, .thinking, .reading] {
            #expect(!RenderPacer.isFastPose(pose), "\(pose)")
        }
    }
}

@Suite("지연 요약 (M6(1) 디버그 계측)")
struct LatencySummaryTests {
    @Test("가장 가까운 순위 백분위")
    func percentiles() {
        let summary = LatencySummary([5, 1, 4, 2, 3, 10, 9, 8, 7, 6])
        #expect(summary.count == 10)
        #expect(summary.p50 == 5)
        #expect(summary.p95 == 10)
        #expect(summary.max == 10)
        #expect(LatencySummary([]) == .empty)
        #expect(LatencySummary([42]).p95 == 42)
        #expect(LatencySummary.empty.description == "n=0")
    }
}

@Suite("깜빡임 길이 (M6(1) 잠잠함)")
struct BlinkDurationTests {
    @Test("깜빡임 길이를 늘리면 3fps 간격(0.33초)으로 그려도 매 주기 한 장 이상 감은 눈이 걸린다")
    func calmBlinkIsCaught() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 12)
        var actor = try! #require(h.actor("lead-1"))
        actor.expression = .neutral  // 웃는 얼굴·졸린 얼굴은 깜빡이지 않음
        func closedFrames(blink: Double, from start: Double) -> Int {
            stride(from: start, to: start + 4.6, by: 1.0 / 3).filter {
                RigAnimator.pose(for: actor, time: $0, blinkDuration: blink).eyeScale < 1
            }.count
        }
        for offset in stride(from: 0.0, to: 0.34, by: 0.05) {
            #expect(closedFrames(blink: RenderPacer.calmBlinkDuration, from: 100 + offset) >= 1, "시작 \(offset)")
        }
        // 기본(0.14초)은 3fps에서 자주 빠짐
        let missed = stride(from: 0.0, to: 0.33, by: 0.03).filter { closedFrames(blink: 0.14, from: 100 + $0) == 0 }.count
        #expect(missed > 0)
    }
}

@Suite("움직이는 가구 그림 되풀이 (M6(1))")
struct LiveFurnitureRepeatTests {
    @Test("안마 롤러는 2.6초 주기로 같은 그림, 모니터 진행 막대는 3초 주기로 같은 그림 (구운 텍스처를 다시 씀)")
    func repeats() {
        let step = 1.0 / 15
        for k in 0..<39 {
            let t = Double(k) * step
            #expect(OfficeArt.massageRoller(time: t) == OfficeArt.massageRoller(time: t + 2.6 * 7))
        }
        var distinct = Set<[ArtShape]>()
        for k in 0..<2_000 { distinct.insert(OfficeArt.massageRoller(time: Double(k) * step)) }
        #expect(distinct.count <= 39)
        var bars = Set<[ArtShape]>()
        for k in 0..<2_000 { bars.insert(OfficeArt.monitorProgress(at: MapPoint(300, 400), time: Double(k) * step, seed: "sub-1")) }
        #expect(bars.count <= 90)
    }
}
