import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// 127.0.0.1 전용 훅 수신 서버 (설계서 §4, §12.1).
///
/// macOS와 Linux 모두에서 동작하도록 BSD 소켓으로 직접 만들었습니다. 덕분에 서버와 훅 스크립트를
/// 클라우드(Linux)에서도 끝에서 끝까지 테스트할 수 있습니다.
///
/// - 연결은 동시에 처리하되, 받은 훅은 도착한 순서대로 `handler`에 넘깁니다 (직렬 큐).
/// - `handler`는 백그라운드 큐에서 불립니다. 앱은 메인 액터로 넘겨서 처리합니다.
/// - 연결 하나는 모두 합쳐 `connectionDeadline`(3초) 안에 끝나야 하고(넘으면 408), 동시에 `maxConnections`개까지
///   받습니다(넘으면 503). 머리줄을 다 받으면 본문을 기다리기 전에 토큰부터 검사합니다. 거절한 수는 상태 코드별로 셉니다.
public final class HookServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable, CustomStringConvertible {
        case socket(Int32)
        case listen(Int32)
        case noFreePort

        public var description: String {
            switch self {
            case .socket(let code): "소켓을 만들 수 없습니다 (errno \(code))"
            case .listen(let code): "연결 대기를 시작할 수 없습니다 (errno \(code))"
            case .noFreePort: "사용할 수 있는 포트가 없습니다"
            }
        }
    }

    public static let defaultPort: UInt16 = 47821
    /// 연결 하나에 주는 전체 시간 (훅 스크립트의 curl은 1초 안에 끝남)
    public static let connectionDeadline: TimeInterval = 3
    /// 동시에 처리하는 연결 수 상한 (훅은 도구 호출마다 하나씩, 병렬 도구여도 몇 개)
    public static let maxConnections = 32

    private let policy: HookRequestPolicy
    private let handler: @Sendable (HookDelivery) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var boundPort: UInt16 = 0
    private var activeConnections = 0
    private var rejections: [Int: Int] = [:]
    private let deadline: TimeInterval
    private let connectionLimit: Int
    /// 테스트용: 202를 보낸 직후 그 연결 스레드에서 부릅니다 (스레드가 늦게 깨는 경우를 시간 없이 재현). 시작 전에만 정합니다.
    var afterAcceptResponse: (@Sendable (HookDelivery) -> Void)?
    private let connectionQueue = DispatchQueue(label: "claude-office.hook.connections", attributes: .concurrent)
    private let deliveryQueue = DispatchQueue(label: "claude-office.hook.delivery")
    private let acceptQueue = DispatchQueue(label: "claude-office.hook.accept")

    public init(token: String, deadline: TimeInterval = HookServer.connectionDeadline, maxConnections: Int = HookServer.maxConnections,
                handler: @escaping @Sendable (HookDelivery) -> Void) {
        self.policy = HookRequestPolicy(token: token)
        self.deadline = deadline
        self.connectionLimit = maxConnections
        self.handler = handler
    }

    /// 지금 처리 중인 연결 수 (테스트가 시간 대신 이 조건을 기다림)
    public var activeConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeConnections
    }

    /// 거절한 요청 수 (상태 코드 → 수). 서버를 만든 뒤부터 셉니다.
    public var rejectedCounts: [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        return rejections
    }

    deinit {
        stop()
    }

    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// 선호 포트부터 차례로 시도하고, 모두 사용 중이면 운영체제가 고른 포트를 씁니다.
    @discardableResult
    public func start(preferredPort: UInt16 = HookServer.defaultPort, attempts: Int = 20) throws -> UInt16 {
        stop()
        var candidates = (0..<max(attempts, 0)).compactMap { offset -> UInt16? in
            let value = Int(preferredPort) + offset
            return preferredPort == 0 || value > Int(UInt16.max) ? nil : UInt16(value)
        }
        candidates.append(0)

        for candidate in candidates {
            let fd = socket(AF_INET, Self.streamType, 0)
            guard fd >= 0 else { throw ServerError.socket(errno) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            #if canImport(Darwin)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = candidate.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                close(fd)
                continue
            }
            guard listen(fd, 32) == 0 else {
                let code = errno
                close(fd)
                throw ServerError.listen(code)
            }

            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            let port = UInt16(bigEndian: actual.sin_port)

            lock.lock()
            listenFD = fd
            running = true
            boundPort = port
            lock.unlock()

            acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
            return port
        }
        throw ServerError.noFreePort
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        running = false
        boundPort = 0
        lock.unlock()
        if fd >= 0 {
            // 대기 루프가 poll로 깨어 확인하므로 닫기만 하면 됩니다
            close(fd)
        }
    }

    // MARK: - 내부

    private static var streamType: Int32 {
        #if canImport(Darwin)
            SOCK_STREAM
        #else
            Int32(SOCK_STREAM.rawValue)
        #endif
    }

    private static var sendFlags: Int32 {
        #if os(Linux)
            Int32(MSG_NOSIGNAL)
        #else
            0
        #endif
    }

    private func isCurrent(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && listenFD == fd
    }

    private func acceptLoop(_ fd: Int32) {
        while isCurrent(fd) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            guard isCurrent(fd) else { break }
            if ready <= 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 {
                // EMFILE·ENFILE(파일 서술자 바닥) 등은 곧바로 다시 실패하므로 잠깐 쉽니다 (바쁜 대기 막기)
                let code = errno
                if code != EINTR && code != EAGAIN && code != ECONNABORTED { usleep(100_000) }
                continue
            }
            configureClient(client)
            lock.lock()
            let admitted = activeConnections < connectionLimit
            if admitted { activeConnections += 1 }
            lock.unlock()
            guard admitted else {
                reject(client, status: 503)
                close(client)
                continue
            }
            connectionQueue.async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.serve(client)
                self.lock.lock()
                self.activeConnections -= 1
                self.lock.unlock()
            }
        }
    }

    private func configureClient(_ client: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        let endAt = Date().addingTimeInterval(deadline)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var result = HTTPParseResult.incomplete
        var headChecked = false
        while case .incomplete = result {
            let remaining = endAt.timeIntervalSinceNow
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard remaining > 0, poll(&descriptor, 1, Int32(max(1, remaining * 1000))) > 0 else {
                reject(client, status: 408)  // 전체 시간 초과 (천천히 보내는 연결이 자리를 오래 잡지 않게)
                return
            }
            let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            guard count > 0 else {
                if !buffer.isEmpty { tally(rejection: 400) }  // 보내다 끊김
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            if !headChecked, case .head(let head, _, _) = HTTPRequestParser.parseHead(buffer) {
                headChecked = true
                // 토큰이 틀린 요청은 본문을 기다리지 않고 바로 거절합니다
                if case .reject(let status, _) = policy.evaluateHead(head) {
                    reject(client, status: status)
                    return
                }
            }
            result = HTTPRequestParser.parse(buffer, maxBodyBytes: policy.maxBodyBytes)
        }

        switch result {
        case .incomplete:
            return
        case .tooLarge:
            reject(client, status: 413)
        case .invalid:
            reject(client, status: 400)
        case .complete(let request):
            switch policy.evaluate(request) {
            case .reject(let status, _):
                reject(client, status: status)
            case .accept(let body, let term, let hostSession):
                // 훅 스크립트가 아직 응답을 기다리는 동안 프로세스를 찾습니다 (중간 셸이 있어도 살아 있음)
                let process = hostSession == nil
                    ? HookRequestPolicy.hookParentPID(request.headers).flatMap(ProcessInspector.claudeProcess(fromHookParent:))
                    : nil
                let delivery = HookDelivery(body: body, term: term, hostSession: hostSession, process: process,
                                            app: HookRequestPolicy.appBundleID(request.headers), receivedAt: Date())
                let handler = self.handler
                // 줄에 먼저 넣고 나서 답합니다. 답한 뒤에 넣으면, 202를 받은 Claude Code가 바로 보낸 다음 훅이 다른 연결
                // 스레드에서 먼저 줄에 들어가 순서가 뒤집힐 수 있었습니다(부하 테스트에서 재현, 개선 7(5)).
                deliveryQueue.async { handler(delivery) }
                respond(client, status: 202)
                afterAcceptResponse?(delivery)
            }
        }
    }

    private func tally(rejection status: Int) {
        lock.lock()
        rejections[status, default: 0] += 1
        lock.unlock()
    }

    private func reject(_ client: Int32, status: Int) {
        tally(rejection: status)
        respond(client, status: status)
    }

    private func respond(_ client: Int32, status: Int) {
        let data = [UInt8](HTTPResponse.serialize(status: status))
        var offset = 0
        while offset < data.count {
            let sent = data[offset...].withUnsafeBytes { send(client, $0.baseAddress, $0.count, Self.sendFlags) }
            if sent <= 0 { return }
            offset += sent
        }
    }
}
