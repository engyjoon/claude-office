import Darwin
import Foundation
import OfficeCore
import OfficeStage

/// 성능 디버그 계측 (설계서 §8.3, M6(1)). 기본은 꺼져 있습니다.
///
/// 켜기: `defaults write com.engyjoon.claudeoffice debug.perfProbe -bool true` 후 앱을 다시 켜거나,
/// 환경 변수 `CLAUDE_OFFICE_PERF=1`로 실행. 10초마다 `~/Library/Logs/Claude Office/perf.log`에 한 줄씩 남깁니다.
///
/// - 씬별 실제 갱신 빈도: SpriteKit `update`가 불린 수 ÷ 10초 (멈춰 있으면 0), 그 구간의 빈도 단계 비율
/// - 모델 타이머 빈도 (무대 시간 흘리기)
/// - 훅 → 무대 적용 지연: 서버가 요청을 다 받은 때(`HookDelivery.receivedAt`) → 엔진·무대에 지시를 넘긴 때
/// - 훅 → 화면 지연: 같은 시작 → 그 뒤 처음으로 보이는 씬이 그 프레임을 그리기 직전(`didFinishUpdate`).
///   보이는 씬이 없으면 재지 않고 "안 보임"으로 셉니다.
@MainActor
final class PerfProbe {
    static let shared: PerfProbe? = isEnabled ? PerfProbe() : nil

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_OFFICE_PERF"] == "1" || UserDefaults.standard.bool(forKey: "debug.perfProbe")
    }

    static let window: TimeInterval = 10

    private var frames: [String: Int] = [:]
    private var paceTime: [String: [RenderPace: TimeInterval]] = [:]
    private var currentPace: [String: (pace: RenderPace, since: Date)] = [:]
    private var modelTicks = 0
    /// 진단용 카운터 (펄스 요청 수 등)
    private var counters: [String: Int] = [:]
    private var applyLatencies: [Double] = []
    private var screenLatencies: [Double] = []
    private var pending: [Date] = []
    private var unseen = 0
    private var windowStart = Date()
    private var cpuStart = PerfProbe.cpuSeconds()
    private var timer: Timer?
    private let logURL: URL

    private init() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude Office", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("perf.log")
        write("# 시작: pid \(ProcessInfo.processInfo.processIdentifier), 텍스처 배율 \(ShapeBaker.scale)")
        let timer = Timer(timeInterval: Self.window, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 씬이 프레임을 그리기 직전 (SpriteKit `didFinishUpdate`)
    func frameRendered(_ scene: String, visible: Bool) {
        frames[scene, default: 0] += 1
        guard visible, !pending.isEmpty else { return }
        let now = Date()
        screenLatencies += pending.map { now.timeIntervalSince($0) * 1000 }
        pending.removeAll()
    }

    func count(_ key: String) {
        counters[key, default: 0] += 1
    }

    func modelTicked() {
        modelTicks += 1
    }

    func paceChanged(_ scene: String, to pace: RenderPace) {
        let now = Date()
        if let current = currentPace[scene] {
            guard current.pace != pace else { return }
            paceTime[scene, default: [:]][current.pace, default: 0] += now.timeIntervalSince(max(current.since, windowStart))
        }
        currentPace[scene] = (pace, now)
    }

    /// 훅의 연출 지시를 무대에 넘겼음
    func hookApplied(receivedAt: Date, anyVisible: Bool) {
        applyLatencies.append(Date().timeIntervalSince(receivedAt) * 1000)
        if anyVisible {
            pending.append(receivedAt)
        } else {
            unseen += 1
        }
    }

    private func flush() {
        let now = Date()
        let span = now.timeIntervalSince(windowStart)
        // 보이는 씬이 2초 넘게 그리지 않은 훅은 버림 (그사이 창이 가려졌음)
        let stale = pending.filter { now.timeIntervalSince($0) > 2 }
        unseen += stale.count
        pending.removeAll { now.timeIntervalSince($0) > 2 }

        var parts: [String] = []
        for scene in ["office", "mini"] {
            var share = paceTime[scene] ?? [:]
            if let current = currentPace[scene] {
                share[current.pace, default: 0] += now.timeIntervalSince(max(current.since, windowStart))
            }
            let shares = [RenderPace.active, .working, .ambient, .calm, .paused].compactMap { pace -> String? in
                guard let t = share[pace], t > 0.05 else { return nil }
                return "\(pace) \(Int((t / span * 100).rounded()))%"
            }.joined(separator: ", ")
            let fps = Double(frames[scene] ?? 0) / span
            parts.append(String(format: "%@ %.1ffps (%@)", scene, fps, shares.isEmpty ? "-" : shares))
        }
        parts.append(String(format: "model %.1fHz", Double(modelTicks) / span))
        parts.append("hook→stage ms \(LatencySummary(applyLatencies))")
        parts.append("hook→screen ms \(LatencySummary(screenLatencies))" + (unseen > 0 ? " (안 보임 \(unseen))" : ""))
        parts.append(String(format: "textures %d (%.1fMB) large %@", ShapeBaker.cachedCount, Double(ShapeBaker.cachedBytes) / 1_048_576,
            ShapeBaker.largeBytes.map { "\($0.key)=\(String(format: "%.1f", Double($0.value) / 1_048_576))MB" }.sorted().joined(separator: ",")))
        if !counters.isEmpty { parts.append(counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
        // 이 구간의 프로세스 CPU (모든 스레드, 코어 하나 = 100%). 훅이 없고 active가 없는 구간이 대기 값입니다.
        let cpu = Self.cpuSeconds()
        parts.insert(String(format: "cpu %.2f%%", (cpu - cpuStart) / span * 100), at: 0)
        cpuStart = cpu
        write(ISO8601DateFormatter().string(from: now) + " " + parts.joined(separator: " | "))

        frames.removeAll()
        counters.removeAll()
        paceTime.removeAll()
        modelTicks = 0
        applyLatencies.removeAll()
        screenLatencies.removeAll()
        unseen = 0
        windowStart = now
    }

    /// 이 프로세스가 지금까지 쓴 CPU 시간 (사용자 + 시스템, 초)
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
