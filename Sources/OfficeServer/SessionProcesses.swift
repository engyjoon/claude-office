import Foundation
import OfficeCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// 프로세스 하나 (번호 + 시작 시각). 같은 번호를 다른 프로세스가 다시 받아도 시작 시각이 달라 구별됩니다.
public struct ProcessIdentity: Hashable, Sendable, CustomStringConvertible {
    public let pid: Int32
    /// 시작 시각 (마이크로초, 운영체제마다 기준이 다름). 0이면 모름(번호만 봄).
    public let startedAt: UInt64

    public init(pid: Int32, startedAt: UInt64) {
        self.pid = pid
        self.startedAt = startedAt
    }

    public var description: String { "PID \(pid)" }
}

/// 훅을 보낸 Claude Code 프로세스를 찾고 살아 있는지 봅니다 (개선 7, 설계서 §4.2·§5.2).
///
/// 훅 스크립트는 자기 `$PPID`를 `X-Office-Pid`로 보냅니다. Claude Code 2.1.321에서 훅 스크립트의 부모는 Claude Code
/// 자신입니다(실측: `/bin/sh` 스크립트 → 부모 `claude`). 다른 버전·설정에서 중간 셸(`sh -c`)이 끼면 그 셸은 훅과 함께
/// 끝나므로 세션을 잘못 퇴근시키게 됩니다. 그래서 셸이면 그 부모로 올라갑니다. 실행 파일 이름은 설치 방식마다 달라
/// (`claude`, 버전 번호, npm의 `node`) 이름으로 고르지 않고 셸만 건너뜁니다.
///
/// 프로세스 정보는 훅이 아직 응답을 기다리는 동안(서버가 202를 보내기 전) 읽으므로 중간 셸도 살아 있습니다.
public enum ProcessInspector {
    /// 건너뛸 셸 이름
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "fish", "env"]

    struct Info: Hashable {
        let parent: Int32
        let name: String
        let startedAt: UInt64
    }

    /// 훅 스크립트의 부모 PID에서 Claude Code 프로세스를 찾습니다. 못 찾으면 nil (그 세션은 PID로 퇴근시키지 않음).
    public static func claudeProcess(fromHookParent pid: Int32) -> ProcessIdentity? {
        var current = pid
        for _ in 0..<4 {
            guard current > 1, let info = info(current) else { return nil }
            if !shells.contains(info.name) { return ProcessIdentity(pid: current, startedAt: info.startedAt) }
            current = info.parent
        }
        return nil
    }

    /// 그 프로세스가 아직 있는지. 번호가 같아도 시작 시각이 다르면(번호 재사용) 없는 것으로 봅니다.
    public static func isAlive(_ process: ProcessIdentity) -> Bool {
        if let info = info(process.pid) {
            return process.startedAt == 0 || info.startedAt == 0 || info.startedAt == process.startedAt
        }
        // 정보를 못 읽는 환경: 신호 0으로 확인 (EPERM은 다른 사용자의 살아 있는 프로세스)
        return kill(process.pid, 0) == 0 || errno == EPERM
    }

    static func info(_ pid: Int32) -> Info? {
        #if canImport(Darwin)
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var process = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, UInt32(mib.count), &process, &size, nil, 0) == 0, size > 0, process.kp_proc.p_pid == pid else {
                return nil
            }
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let start = process.kp_proc.p_starttime
            return Info(parent: process.kp_eproc.e_ppid, name: name,
                        startedAt: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
        #else
            // /proc/<pid>/stat: "pid (comm) state ppid … starttime(22번째)"
            guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")")
            else { return nil }
            let name = String(text[text.index(after: open)..<close])
            let fields = text[text.index(after: close)...].split(separator: " ")
            guard fields.count > 19, let parent = Int32(fields[1]), let start = UInt64(fields[19]) else { return nil }
            return Info(parent: parent, name: name, startedAt: start)
        #endif
    }
}

/// 터미널 세션마다 마지막으로 받은 Claude Code 프로세스와 띄운 앱(번들 id)을 기억합니다 (개선 7).
///
/// 코어(`OfficeState`)는 프로세스를 모르게 두고, 앱이 이 값을 들고 있다가 몇 초마다 `sweep`으로 죽은 프로세스의 세션을
/// `sessionEnded` 이벤트로 바꿔 엔진에 넣습니다. 그러면 SessionEnd를 받은 것처럼 퇴근합니다(승진·행 닫기·알림 지우기는
/// 리듀서가 함). 데스크톱 앱 세션은 데스크톱 목록이 맡으므로 기억하지 않고, PID를 못 받은 세션(옛 훅 스크립트,
/// 앱을 켠 뒤 아직 훅이 없음)은 건드리지 않습니다.
public struct SessionProcessTracker: Sendable {
    public private(set) var processes: [SessionID: ProcessIdentity] = [:]
    private var apps: [SessionID: String] = [:]

    public init() {}

    /// 훅 하나를 받았을 때. `desktop`이면 데스크톱 앱 세션, `ended`면 SessionEnd.
    public mutating func note(session: SessionID, process: ProcessIdentity?, app: String?, desktop: Bool, ended: Bool) {
        if ended {
            processes[session] = nil
            apps[session] = nil
            return
        }
        if let app { apps[session] = app }
        if desktop {
            processes[session] = nil
        } else if let process {
            processes[session] = process  // `claude --resume`으로 다른 프로세스가 이어받으면 새 것으로
        }
    }

    /// 그 세션을 띄운 앱의 번들 id (`__CFBundleIdentifier`). 모르면 nil.
    public func app(for session: SessionID) -> String? { apps[session] }

    /// 프로세스가 죽은 세션을 잊고, 그 세션들의 `sessionEnded` 이벤트를 돌려줍니다.
    public mutating func sweep(at now: Date, isAlive: (ProcessIdentity) -> Bool) -> [OfficeEvent] {
        let dead = processes.filter { !isAlive($0.value) }.keys.sorted()
        for session in dead {
            processes[session] = nil
            apps[session] = nil
        }
        return dead.map { OfficeEvent(session: $0, cwd: nil, at: now, kind: .sessionEnded(reason: Self.endReason)) }
    }

    /// 프로세스가 사라져 앱이 대신 넣은 SessionEnd의 reason
    public static let endReason = "process_exited"
}
