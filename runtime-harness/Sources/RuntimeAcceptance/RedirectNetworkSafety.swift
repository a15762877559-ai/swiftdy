import Foundation
import Darwin
@preconcurrency import Network

enum RedirectProbeError: String, Error {
    case policy = "REDIRECT_POLICY_REJECTED", dns = "DNS_LOOKUP_FAILED"
    case address = "NON_PUBLIC_OR_UNSUPPORTED_ADDRESS", proxy = "PINNED_TUNNEL_FAILED"
    case budget = "REQUEST_BUDGET_REJECTED"
}

// No address strings are Codable. A checked immutable destination is required to create a production tunnel.
struct VettedProbeDestination: Sendable {
    let host: String
    fileprivate let address: String
    let addressCount: Int
    fileprivate init(host: String, address: String, addressCount: Int) {
        self.host = host; self.address = address; self.addressCount = addressCount
    }
}

enum RedirectNetworkSafety {
    static func publicAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET,value,&v4) == 1 {
            let n = UInt32(bigEndian:v4.s_addr)
            func subnet(_ base: UInt32, _ mask: UInt32) -> Bool { n & mask == base }
            return ![subnet(0x00000000,0xff000000),subnet(0x0a000000,0xff000000),
                subnet(0x64400000,0xffc00000),subnet(0x7f000000,0xff000000),
                subnet(0xa9fe0000,0xffff0000),subnet(0xac100000,0xfff00000),
                subnet(0xc0000000,0xffffff00),subnet(0xc0000200,0xffffff00),
                subnet(0xc0586300,0xffffff00),subnet(0xc0a80000,0xffff0000),
                subnet(0xc6120000,0xfffe0000),subnet(0xc6336400,0xffffff00),
                subnet(0xcb007100,0xffffff00),n >= 0xe0000000].contains(true)
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6,value,&v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of:&v6) { Array($0) }
        // Only ordinary global unicast; deny mapped/compatible, local, multicast, transition and documentation ranges.
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x3f && bytes[1] == 0xfe { return false } // Returned 6bone range.
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false } // RFC 9637 documentation.
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false } // 6to4 embeds another destination.
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] < 0x02 { return false } // IETF special-purpose block, including Teredo/ORCHID.
            if bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        }
        return true
    }
    static func vet(host: String, addresses: [String]) throws -> VettedProbeDestination {
        guard host == RedirectProbePolicy.targetHost, !addresses.isEmpty, addresses.count <= 32,
              addresses.allSatisfy(publicAddress) else { throw RedirectProbeError.address }
        return VettedProbeDestination(host:host,address:addresses[0],addressCount:addresses.count)
    }
    static func resolve(_ url: URL) async throws -> VettedProbeDestination {
        guard RedirectProbePolicy.targetAllowed(url) else { throw RedirectProbeError.policy }
        return try await Task.detached {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(RedirectProbePolicy.targetHost,"443",&hints,&result) == 0, let first = result else {
                throw RedirectProbeError.dns
            }
            defer { freeaddrinfo(first) }
            var values: [String] = [], current: UnsafeMutablePointer<addrinfo>? = first
            var nodes = 0
            while let entry = current {
                nodes += 1; guard nodes <= 64 else { throw RedirectProbeError.address }
                let record = entry.pointee
                guard record.ai_family == AF_INET || record.ai_family == AF_INET6 else { throw RedirectProbeError.address }
                var text = [CChar](repeating:0,count:Int(NI_MAXHOST))
                guard getnameinfo(record.ai_addr,record.ai_addrlen,&text,socklen_t(text.count),nil,0,NI_NUMERICHOST) == 0 else {
                    throw RedirectProbeError.dns
                }
                let value = String(cString:text)
                if !values.contains(value) { values.append(value) }
                current = record.ai_next
            }
            return try vet(host:RedirectProbePolicy.targetHost,addresses:values)
        }.value
    }
}

struct PinnedTunnelEvidence: Codable, Sendable {
    var accepted_connections = 0
    var rejected_connections = 0
    var outbound_connections = 0
    var connect_authority_matched = false
    var credential_headers_seen = false
    var public_address_pinned = false
    var stopped = false
    var failure_category: String?
}

// A single CONNECT tunnel connects ONLY to the vetted numeric address. URLSession retains the original
// HTTPS hostname for SNI and normal certificate validation. This is per-session routing, not a system proxy change.
final class PinnedProbeTunnel: @unchecked Sendable {
    private let queue = DispatchQueue(label:"doustudio.redirect.pin")
    private let host: String, address: String
    private let targetPort: UInt16
    private var listener: NWListener?
    private var client: NWConnection?, remote: NWConnection?
    private var waiter: CheckedContinuation<Void, Error>?
    private var used = false
    private var evidence = PinnedTunnelEvidence()
    private(set) var port = 0
    private init(host: String, address: String, port: UInt16, publicPin: Bool) {
        self.host = host; self.address = address; self.targetPort = port
        evidence.public_address_pinned = publicPin
    }
    static func start(_ destination: VettedProbeDestination) async throws -> PinnedProbeTunnel {
        guard destination.host == RedirectProbePolicy.targetHost, RedirectNetworkSafety.publicAddress(destination.address) else {
            throw RedirectProbeError.address
        }
        let value = PinnedProbeTunnel(host:destination.host,address:destination.address,port:443,publicPin:true)
        try await value.open(); return value
    }
    // Test-only factory: fixed loopback destination and fixed CONNECT authority, no production DNS bypass switch.
    static func fixture(port: UInt16) async throws -> PinnedProbeTunnel {
        guard port >= 1024 else { throw RedirectProbeError.policy }
        let value = PinnedProbeTunnel(host:RedirectProbePolicy.targetHost,address:"127.0.0.1",port:port,publicPin:false)
        try await value.open(); return value
    }
    private func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.waiter = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
                    let listener = try NWListener(using:parameters,on:.any); self.listener = listener
                    listener.newConnectionHandler = { connection in
                        if self.used { self.evidence.rejected_connections += 1; connection.cancel(); return }
                        self.used = true; self.evidence.accepted_connections += 1; self.client = connection
                        connection.start(queue:self.queue); self.readConnect(Data())
                    }
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard let port = listener.port, port.rawValue >= 1024 else { self.fail(); return }
                            self.port = Int(port.rawValue); let waiter = self.waiter; self.waiter = nil; waiter?.resume()
                        case .failed: self.fail()
                        default: break
                        }
                    }
                    listener.start(queue:self.queue)
                    self.queue.asyncAfter(deadline:.now() + 5) { if self.waiter != nil { self.fail() } }
                } catch { self.fail() }
            }
        }
    }
    private func fail() {
        evidence.failure_category = "PINNED_TUNNEL_FAILED"
        let savedWaiter = self.waiter; self.waiter = nil; savedWaiter?.resume(throwing:RedirectProbeError.proxy)
        close()
    }
    private func close() {
        evidence.stopped = true; client?.cancel(); remote?.cancel(); listener?.cancel()
    }
    private func readConnect(_ previous: Data) {
        client?.receive(minimumIncompleteLength:1,maximumLength:4096) { data,_,complete,error in
            guard error == nil, let data, !data.isEmpty, previous.count + data.count <= 8192 else { self.fail(); return }
            var buffer = previous; buffer.append(data)
            guard let end = buffer.range(of:Data([13,10,13,10])) else {
                if complete { self.fail() } else { self.readConnect(buffer) }; return
            }
            guard end.upperBound == buffer.endIndex, let text = String(data:buffer,encoding:.ascii) else { self.fail(); return }
            let lines = text.components(separatedBy:"\r\n")
            let badHeader = lines.dropFirst().contains { line in
                ["authorization:","proxy-authorization:","cookie:"].contains { line.lowercased().hasPrefix($0) }
            }
            self.evidence.credential_headers_seen = badHeader
            guard !badHeader, ["CONNECT \(self.host):443 HTTP/1.1","CONNECT \(self.host):443 HTTP/1.0"].contains(lines.first ?? "") else { self.fail(); return }
            self.evidence.connect_authority_matched = true
            let connection = NWConnection(host:NWEndpoint.Host(self.address),port:NWEndpoint.Port(rawValue:self.targetPort)!,using:.tcp)
            self.remote = connection; self.evidence.outbound_connections = 1
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.client?.send(content:Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),completion:.contentProcessed { error in
                        if error != nil { self.fail(); return }
                        if let client = self.client { self.pipe(client,connection); self.pipe(connection,client) }
                    })
                case .failed: self.fail()
                default: break
                }
            }
            connection.start(queue:self.queue)
        }
    }
    private func pipe(_ source: NWConnection, _ destination: NWConnection) {
        // Backpressure: at most one 16 KiB ciphertext piece per direction. Nothing is logged or persisted.
        source.receive(minimumIncompleteLength:1,maximumLength:16384) { data,_,complete,error in
            guard error == nil, let data, !data.isEmpty else { self.close(); return }
            destination.send(content:data,completion:.contentProcessed { error in
                if error != nil || complete { self.close() } else { self.pipe(source,destination) }
            })
        }
    }
    func finish() async -> PinnedTunnelEvidence {
        await withCheckedContinuation { continuation in
            queue.async { self.close(); continuation.resume(returning:self.evidence) }
        }
    }
}
