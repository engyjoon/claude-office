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

    private let policy: HookRequestPolicy
    private let handler: @Sendable (HookDelivery) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var boundPort: UInt16 = 0
    private let connectionQueue = DispatchQueue(label: "claude-office.hook.connections", attributes: .concurrent)
    private let deliveryQueue = DispatchQueue(label: "claude-office.hook.delivery")
    private let acceptQueue = DispatchQueue(label: "claude-office.hook.accept")

    public init(token: String, handler: @escaping @Sendable (HookDelivery) -> Void) {
        self.policy = HookRequestPolicy(token: token)
        self.handler = handler
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
            if client < 0 { continue }
            configureClient(client)
            connectionQueue.async { [weak self] in
                self?.serve(client)
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
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var result = HTTPParseResult.incomplete
        while case .incomplete = result {
            let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return }  // 시간 초과 또는 연결 끊김
            buffer.append(contentsOf: chunk[0..<count])
            result = HTTPRequestParser.parse(buffer, maxBodyBytes: policy.maxBodyBytes)
        }

        switch result {
        case .incomplete:
            return
        case .tooLarge:
            respond(client, status: 413)
        case .invalid:
            respond(client, status: 400)
        case .complete(let request):
            switch policy.evaluate(request) {
            case .reject(let status, _):
                respond(client, status: status)
            case .accept(let body, let term):
                respond(client, status: 202)
                let delivery = HookDelivery(body: body, term: term, receivedAt: Date())
                let handler = self.handler
                deliveryQueue.async { handler(delivery) }
            }
        }
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
