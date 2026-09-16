import Foundation
import Network

/// What the phone can and cannot reach, asked hop by hop.
///
/// "Request timed out" from URLSession says nothing about *where* the packet
/// died: the app's own policy, the phone's VPN, the tailnet, or the server.
/// This runs three independent probes so the pairing screen can name the
/// hop. Each has a short deadline and never throws; the report is prose
/// because its reader is a person on a phone.
public enum ReachabilityProbe {
    public struct Report: Sendable, Equatable {
        /// Whether a `utun` interface carrying a 100.64/10 address is up:
        /// the tailnet VPN is connected.
        public var tailnetInterfaceUp: Bool
        /// The phone's own tailnet address, when it has one.
        public var ownTailnetAddress: String?
        /// Raw TCP connect to host:port through Network.framework, which
        /// bypasses URLSession and App Transport Security entirely.
        public var tcpConnect: Result
        /// `GET /health` through URLSession, the path the app really uses.
        public var httpHealth: Result

        public enum Result: Sendable, Equatable {
            case ok(String)
            case failed(String)
        }

        public var summary: String {
            var lines: [String] = []
            lines.append(tailnetInterfaceUp
                ? "Tailnet VPN: up" + (ownTailnetAddress.map { " (\($0))" } ?? "")
                : "Tailnet VPN: no tailnet interface on this phone. Open Tailscale and connect.")
            switch tcpConnect {
            case .ok(let detail): lines.append("TCP connect: ok (\(detail))")
            case .failed(let why): lines.append("TCP connect: \(why)")
            }
            switch httpHealth {
            case .ok(let detail): lines.append("HTTP /health: ok (\(detail))")
            case .failed(let why): lines.append("HTTP /health: \(why)")
            }
            return lines.joined(separator: "\n")
        }
    }

    public static func run(host: String, port: UInt16, timeout: TimeInterval = 5) async -> Report {
        let (up, own) = tailnetInterface()
        async let tcp = tcpConnect(host: host, port: port, timeout: timeout)
        async let http = httpHealth(host: host, port: port, timeout: timeout)
        return Report(tailnetInterfaceUp: up, ownTailnetAddress: own,
                      tcpConnect: await tcp, httpHealth: await http)
    }

    // MARK: - Probes

    /// Walks the interface list for a utun carrying a CGNAT (100.64/10)
    /// address, which is what Tailscale assigns.
    static func tailnetInterface() -> (Bool, String?) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (false, nil) }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            var addr = sockaddr_in()
            memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
            let raw = UInt32(bigEndian: addr.sin_addr.s_addr)
            // 100.64.0.0/10
            if raw >> 22 == 0x64_40_00_00 >> 22 {
                let text = "\(raw >> 24).\((raw >> 16) & 0xff).\((raw >> 8) & 0xff).\(raw & 0xff)"
                return (true, text)
            }
        }
        return (false, nil)
    }

    static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) async -> Report.Result {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failed("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let started = Date()
        return await withCheckedContinuation { continuation in
            let done = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let path = connection.currentPath?.availableInterfaces.first
                        .map { "\($0.name), \($0.type)" } ?? "unknown interface"
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    done.run { continuation.resume(returning: .ok("\(ms) ms via \(path)")) }
                    connection.cancel()
                case .failed(let error):
                    done.run { continuation.resume(returning: .failed(error.localizedDescription)) }
                    connection.cancel()
                case .waiting(let error):
                    // Stays here forever when there is no route; the deadline
                    // below turns that into a timeout with the reason.
                    done.pending = "waiting: \(error.localizedDescription)"
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                done.run {
                    continuation.resume(returning: .failed(
                        "timed out after \(Int(timeout)) s" + (done.pending.map { " (\($0))" } ?? "")))
                }
                connection.cancel()
            }
        }
    }

    static func httpHealth(host: String, port: UInt16, timeout: TimeInterval) async -> Report.Result {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/health"
        guard let url = components.url else { return .failed("bad host") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(80), as: UTF8.self)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return code == 200 ? .ok("\(ms) ms, \(body)") : .failed("HTTP \(code): \(body)")
        } catch let error as URLError {
            return .failed("\(error.localizedDescription) (\(error.code.rawValue))")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// One-shot guard for a continuation that several callbacks race to resume.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        var pending: String?
        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !fired else { return }
            fired = true
            body()
        }
    }
}
