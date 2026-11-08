import AVFoundation
import OfficeCore

/// 효과음 재생기 (설계서 §11.5).
///
/// 레시피(`SoundLibrary`)를 앱 안에서 합성해 `AVAudioPCMBuffer`로 캐시하고, `AVAudioPlayerNode` 4개를 돌려 가며 재생합니다.
/// 울릴지 말지는 코어의 `SoundPolicy`가 정합니다 (켜짐 여부, 사무실이 보이는지, 연속 재생 제한, 동시 재생 수).
/// 소리가 없을 때는 오디오 엔진을 멈춰 CPU를 쓰지 않습니다.
@MainActor
final class SoundPlayer {
    private(set) var settings: SoundSettings
    private var policy: SoundPolicy
    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var nextNode = 0
    private let format: AVAudioFormat
    private let renderer = SoundRenderer(sampleRate: 44_100)
    private var cache: [String: (buffer: AVAudioPCMBuffer, duration: Double)] = [:]
    private var stopWork: DispatchWorkItem?
    private var configurationObserver: NSObjectProtocol?

    /// 블립처럼 무작위 음이 섞인 소리는 몇 가지를 미리 만들어 번갈아 씁니다
    private static let variants = 4

    init(settings: SoundSettings) {
        self.settings = settings
        policy = SoundPolicy(settings: settings)
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for _ in 0..<4 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }
        // 출력 장치가 바뀌면(이어폰 연결 등) 엔진이 멈추므로 다음 재생 때 다시 켭니다
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop() }
        }
    }

    func update(_ settings: SoundSettings) {
        self.settings = settings
        policy.settings = settings
    }

    /// 연출이 낸 효과음. 정책을 통과한 것만 울립니다.
    func play(_ cue: SoundCue, context: SoundContext) {
        guard settings.isEnabled(cue.group) else { return }
        let sound = sound(for: cue)
        guard case .play(let gain) = policy.decide(cue, duration: sound.duration, at: Date(), context: context) else { return }
        output(sound.buffer, gain: gain, duration: sound.duration)
    }

    /// 설정 화면의 미리 듣기. 꺼진 항목이어도 들려줍니다 (음소거면 아주 작게라도 들리도록 최소 음량을 둡니다).
    func preview(_ group: SoundGroup) {
        let sound = sound(for: group.sampleCue)
        output(sound.buffer, gain: max(settings.volume, 0.15), duration: sound.duration)
    }

    // MARK: - 합성과 출력

    private func sound(for cue: SoundCue) -> (buffer: AVAudioPCMBuffer, duration: Double) {
        let variant: Int
        switch cue {
        case .bubble, .chatter, .typing: variant = Int.random(in: 0..<Self.variants)
        default: variant = 0
        }
        let key = "\(cue)#\(variant)"
        if let cached = cache[key] { return cached }
        var rng = SeededRandom(seed: StableHash.fnv1a(key))
        let recipe = SoundLibrary.recipe(for: cue, using: &rng)
        let samples = renderer.render(recipe, noiseSeed: UInt64(variant + 1))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let entry = (buffer, Double(samples.count) / 44_100)
        cache[key] = entry
        return entry
    }

    private func output(_ buffer: AVAudioPCMBuffer, gain: Double, duration: Double) {
        guard startIfNeeded() else { return }
        let node = nodes[nextNode]
        nextNode = (nextNode + 1) % nodes.count
        node.volume = Float(gain)
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
        scheduleStop(after: duration + 2)
    }

    private func startIfNeeded() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            return false  // 출력 장치가 없으면 조용히 넘어갑니다
        }
    }

    /// 마지막 소리가 끝나고 잠시 뒤 엔진을 멈춥니다 (대기 상태 CPU 1% 미만, 설계서 §8.3)
    private func scheduleStop(after seconds: Double) {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.nodes.forEach { $0.stop() }
                self.engine.stop()
            }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
