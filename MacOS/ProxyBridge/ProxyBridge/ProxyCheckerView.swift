import SwiftUI
import Combine
import Darwin

struct ProxyCheckerView: View {
    let config: ProxyBridgeViewModel.ProxyConfig
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ProxyCheckerModel

    init(config: ProxyBridgeViewModel.ProxyConfig) {
        self.config = config
        _model = StateObject(wrappedValue: ProxyCheckerModel(config: config))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Host:").fontWeight(.medium)
                TextField("www.google.com", text: $model.targetHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Text("Port:").fontWeight(.medium)
                TextField("80", text: $model.targetPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Spacer()
                Button("Retest") { model.run() }
                    .disabled(model.isRunning)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                Text(model.log)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(width: 640, height: 460)
        .onAppear { model.run() }
    }
}

final class ProxyCheckerModel: ObservableObject {
    @Published var log = ""
    @Published var targetHost = "www.google.com"
    @Published var targetPort = "80"
    @Published var isRunning = false

    private let config: ProxyBridgeViewModel.ProxyConfig

    init(config: ProxyBridgeViewModel.ProxyConfig) {
        self.config = config
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        log = ""
        let host = targetHost.trimmingCharacters(in: .whitespaces)
        let port = Int(targetPort) ?? 80
        DispatchQueue.global().async {
            self.performTests(targetHost: host, targetPort: port)
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func line(_ text: String) {
        DispatchQueue.main.async { self.log += text + "\n" }
    }

    private func performTests(targetHost: String, targetPort: Int) {
        let proxyHost = config.host
        let proxyPort = config.port
        let isSocks5 = config.type.lowercased() == "socks5"
        let hasAuth = config.username != nil && config.password != nil

        line("Proxy:    \(proxyHost):\(proxyPort)")
        line("Protocol: \(config.type.uppercased())")
        line("Auth:     \(hasAuth ? "yes" : "no")")
        line("Target:   \(targetHost):\(targetPort)")
        line("")

        // Test 1 - reach the proxy
        line("Test 1: Connection to the proxy server")
        guard let (fd1, ms1) = openConnection(host: proxyHost, port: proxyPort) else {
            line("  Could not connect to the proxy")
            line("  Test 1 failed")
            line("")
            line("Testing finished: proxy is not reachable.")
            return
        }
        line(String(format: "  Connection established (%.0f ms)", ms1))
        line("  Test 1 passed")
        line("")

        // Test 2 - go through the proxy to the target
        line("Test 2: Connection through the proxy server")
        var connected = false
        if isSocks5 {
            if socks5Handshake(fd1, hasAuth: hasAuth) {
                let (ok, reason) = socks5Connect(fd1, host: targetHost, port: targetPort)
                connected = ok
                if !ok { line("  SOCKS5 CONNECT failed: \(reason)") }
            } else {
                line("  SOCKS5 handshake or auth failed")
            }
        } else {
            let (ok, firstLine) = httpConnect(fd1, host: targetHost, port: targetPort)
            connected = ok
            if !ok { line("  HTTP CONNECT failed: \(firstLine)") }
        }

        if connected {
            let request = "GET / HTTP/1.0\r\nHost: \(targetHost)\r\nConnection: close\r\n\r\n"
            _ = sendAll(fd1, Array(request.utf8))
            let response = String(bytes: recvBytes(fd1, 512), encoding: .utf8) ?? ""
            let status = response.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? "no response"
            line("  Connection to \(targetHost):\(targetPort) established through the proxy")
            line("  Page loaded: \(status)")
            line("  Test 2 passed")
        } else {
            line("  Test 2 failed")
        }
        Darwin.close(fd1)
        line("")

        // Test 3 - latency (fresh connect to the proxy)
        line("Test 3: Proxy server latency")
        if let (fd3, ms3) = openConnection(host: proxyHost, port: proxyPort) {
            line(String(format: "  Latency = %.0f ms", ms3))
            line("  Test 3 passed")
            Darwin.close(fd3)
        } else {
            line("  Could not measure latency")
            line("  Test 3 failed")
        }
        line("")

        // Test 4 - SOCKS5 UDP ASSOCIATE support
        if isSocks5 {
            line("Test 4: SOCKS5 UDP ASSOCIATE support")
            if let (fd4, _) = openConnection(host: proxyHost, port: proxyPort) {
                if socks5Handshake(fd4, hasAuth: hasAuth) {
                    let (granted, info) = socks5UDPAssociate(fd4)
                    if granted {
                        line("  UDP ASSOCIATE granted; relay = \(info)")
                        line("  UDP is supported by this proxy")
                    } else {
                        line("  UDP ASSOCIATE rejected: \(info)")
                        line("  UDP is not supported by this proxy")
                    }
                } else {
                    line("  Handshake failed")
                }
                Darwin.close(fd4)
            } else {
                line("  Could not connect to the proxy")
            }
            line("")
        }

        line("Testing finished.")
    }

    // MARK: - sockets

    // connects to host:port (v4/v6/hostname), returns the fd and connect time in ms
    private func openConnection(host: String, port: Int, timeout: Int = 5) -> (Int32, Double)? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0 else { return nil }
        defer { freeaddrinfo(result) }

        let start = Date()
        var candidate = result
        while let addr = candidate {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: timeout, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                    return (fd, Date().timeIntervalSince(start) * 1000)
                }
                Darwin.close(fd)
            }
            candidate = addr.pointee.ai_next
        }
        return nil
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        return bytes.withUnsafeBytes { raw -> Bool in
            var sent = 0
            let base = raw.baseAddress!
            while sent < bytes.count {
                let n = send(fd, base + sent, bytes.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func recvBytes(_ fd: Int32, _ maxLen: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: maxLen)
        let n = recv(fd, &buf, maxLen, 0)
        return n > 0 ? Array(buf[0..<n]) : []
    }

    // reads exactly n bytes, nil on timeout/close
    private func recvExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var out = [UInt8]()
        while out.count < n {
            var buf = [UInt8](repeating: 0, count: n - out.count)
            let r = recv(fd, &buf, n - out.count, 0)
            if r <= 0 { return nil }
            out.append(contentsOf: buf[0..<r])
        }
        return out
    }

    // MARK: - SOCKS5

    private func socks5Handshake(_ fd: Int32, hasAuth: Bool) -> Bool {
        let greeting: [UInt8] = hasAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
        guard sendAll(fd, greeting), let resp = recvExact(fd, 2), resp[0] == 0x05 else { return false }

        if resp[1] == 0x00 { return true }
        if resp[1] == 0x02 {
            let user = Array((config.username ?? "").utf8)
            let pass = Array((config.password ?? "").utf8)
            guard user.count <= 255, pass.count <= 255 else { return false }
            var req: [UInt8] = [0x01, UInt8(user.count)]
            req += user
            req.append(UInt8(pass.count))
            req += pass
            guard sendAll(fd, req), let ar = recvExact(fd, 2), ar[1] == 0x00 else { return false }
            return true
        }
        return false
    }

    private func socks5Connect(_ fd: Int32, host: String, port: Int) -> (Bool, String) {
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(min(host.utf8.count, 255))]
        req += Array(host.utf8.prefix(255))
        req.append(UInt8(port >> 8))
        req.append(UInt8(port & 0xFF))
        guard sendAll(fd, req), let head = recvExact(fd, 4), head[0] == 0x05 else { return (false, "no reply") }
        if head[1] != 0x00 { return (false, "REP=0x\(hex(head[1])) (\(socksReason(head[1])))") }
        return (consumeBoundAddress(fd, atyp: head[3]) != nil, "")
    }

    private func socks5UDPAssociate(_ fd: Int32) -> (Bool, String) {
        let req: [UInt8] = [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        guard sendAll(fd, req), let head = recvExact(fd, 4), head[0] == 0x05 else { return (false, "no reply") }
        if head[1] != 0x00 { return (false, "REP=0x\(hex(head[1])) (\(socksReason(head[1])))") }
        guard let relay = consumeBoundAddress(fd, atyp: head[3]) else { return (false, "bad reply") }
        return (true, relay)
    }

    // reads the bound address + port that follows a SOCKS5 reply header, returns "host:port"
    private func consumeBoundAddress(_ fd: Int32, atyp: UInt8) -> String? {
        var host = ""
        switch atyp {
        case 0x01:
            guard let a = recvExact(fd, 4) else { return nil }
            host = "\(a[0]).\(a[1]).\(a[2]).\(a[3])"
        case 0x04:
            guard let a = recvExact(fd, 16) else { return nil }
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                parts.append(String(format: "%x", (UInt16(a[i]) << 8) | UInt16(a[i + 1])))
            }
            host = parts.joined(separator: ":")
        case 0x03:
            guard let l = recvExact(fd, 1)?.first, let d = recvExact(fd, Int(l)) else { return nil }
            host = String(bytes: d, encoding: .utf8) ?? "?"
        default:
            return nil
        }
        guard let p = recvExact(fd, 2) else { return nil }
        return "\(host):\((Int(p[0]) << 8) | Int(p[1]))"
    }

    // MARK: - HTTP CONNECT

    private func httpConnect(_ fd: Int32, host: String, port: Int) -> (Bool, String) {
        let target = host.contains(":") ? "[\(host)]" : host
        var req = "CONNECT \(target):\(port) HTTP/1.1\r\nHost: \(target):\(port)\r\n"
        if let u = config.username, let p = config.password {
            let cred = Data("\(u):\(p)".utf8).base64EncodedString()
            req += "Proxy-Authorization: Basic \(cred)\r\n"
        }
        req += "\r\n"
        guard sendAll(fd, Array(req.utf8)) else { return (false, "write failed") }
        let response = String(bytes: recvBytes(fd, 1024), encoding: .utf8) ?? ""
        let firstLine = response.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? "no response"
        return (response.contains(" 200"), firstLine)
    }

    private func hex(_ b: UInt8) -> String { String(format: "%02x", b) }

    private func socksReason(_ rep: UInt8) -> String {
        switch rep {
        case 0x01: return "general failure"
        case 0x02: return "not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default: return "unknown"
        }
    }
}
