import Foundation
import DouStudioKit

enum SafeStreamError: String, Error, Sendable {
    case scope = "REQUEST_SCOPE_REJECTED"
    case second = "SECOND_MEDIA_REQUEST_REJECTED"
    case buffered = "BUFFERED_FALLBACK_FORBIDDEN"
    case status = "HTTP_STATUS_REJECTED"
    case redirect = "REDIRECT_REJECTED"
    case type = "NON_MEDIA_RESPONSE"
    case empty = "EMPTY_RESPONSE"
    case size = "DECLARED_LENGTH_OVER_BUDGET"
    case budget = "APPLICATION_BYTE_BUDGET_REACHED"
    case range = "INCOMPLETE_RANGE_REJECTED"
    case length = "LENGTH_MISMATCH"
    case network = "NETWORK_ERROR"
    case timeout = "TIMEOUT"
    case cancelled = "CALLER_CANCELLED"
    case buffer = "BOUNDED_BUFFER_OVERFLOW"
}

struct StreamMetrics: Codable, Sendable {
    var delegate_received_bytes: Int64 = 0
    var accepted_bytes: Int64 = 0
    var cancel_requested = false
    var accepted_at_cancel: Int64?
    var cancel_completed = false
    var completion_received = false
    var completion_callbacks = 0
    var terminal_transitions = 0
    var queued_callbacks_after_cancel = 0
    var bytes_after_cancel: Int64 = 0
    var discarded_buffered_bytes = 0
    var max_buffered_bytes = 0
    var max_delegate_callback_bytes = 0
    var backpressure_waits = 0
    var discarded_callback_bytes = 0
    var stream_calls = 0
    var buffered_send_calls = 0
    var rejected_second_requests = 0
    var http_status: Int?
    var declared_bytes: Int64?
    var range_removed = false
    var cookie_removed = false
    var failure: String?
    var cancel_to_completion_ms: Double?
}

private extension NSCondition {
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

/// Single-use media transport. Production callers must supply a previously verified
/// extracted URL and an explicitly audited host allowlist (never workflow URL input).
/// This test executable only constructs the separate, literal-loopback test scope.
final class SafeStreamingTransport: NSObject, StreamingHTTPTransport, URLSessionDataDelegate, @unchecked Sendable {
    static let MAX_MEDIA_BYTES: Int64 = 104857600
    static let MAX_BUFFER_BYTES = 2 * 1024 * 1024
    private let lock = NSCondition()
    private let allowedURL: URL
    private let testLoopback: Bool
    private let verifiedHosts: Set<String>
    private let timeout: TimeInterval
    private let testConsumerDelay: Int
    private var metrics = StreamMetrics()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var headWaiter: CheckedContinuation<StreamHead, Error>?
    private var bodyWaiter: CheckedContinuation<StreamChunk?, Error>?
    private var queue: [Data] = []
    private var queueBytes = 0
    private var prefix = Data()
    private var prefixVerified = false
    private var used = false
    private var finished = false
    private var failure: SafeStreamError?
    private var declared: Int64?
    private var exactBoundary = false
    private var cancelTime: Date?

    init(extractedMediaURL: URL, verifiedMediaHosts: Set<String>, timeout: TimeInterval = 10) {
        allowedURL = extractedMediaURL; verifiedHosts = verifiedMediaHosts
        testLoopback = false; self.timeout = timeout; testConsumerDelay = 0
        super.init()
    }
    // Kept internal to the controlled-test executable; cannot accept an external host.
    init(loopbackURL: URL, timeout: TimeInterval = 10, consumerDelayMilliseconds: Int = 0) throws {
        guard loopbackURL.scheme == "http", loopbackURL.host == "127.0.0.1",
              let port = loopbackURL.port, port >= 1024 else { throw SafeStreamError.scope }
        allowedURL = loopbackURL; testLoopback = true; verifiedHosts = []
        self.timeout = timeout; testConsumerDelay = consumerDelayMilliseconds; super.init()
    }
    func snapshot() -> StreamMetrics { lock.synchronized { metrics } }
    func send(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        lock.synchronized { metrics.buffered_send_calls += 1 }
        throw SafeStreamError.buffered
    }
    private func prepare(_ request: SignedRequest, _ options: TransportOptions) throws -> URLRequest {
        try lock.synchronized {
            guard !used else { metrics.rejected_second_requests += 1; throw SafeStreamError.second }
            used = true; metrics.stream_calls += 1
            guard request.method == .get, request.body == nil, options.proxy == nil, options.extraHeaders.isEmpty,
                  let url = request.url, url == allowedURL, url.user == nil, url.password == nil, url.fragment == nil,
                  (testLoopback || (url.scheme == "https" && (url.port == nil || url.port == 443) && verifiedHosts.contains(url.host ?? ""))),
                  !request.headers.keys.contains(where: { ["authorization","proxy-authorization"].contains($0.lowercased()) }) else { throw SafeStreamError.scope }
            let ranges = request.headers.filter { $0.key.lowercased() == "range" }
            guard ranges.count <= 1, ranges.isEmpty || ranges.first?.value == "bytes=0-" else { throw SafeStreamError.scope }
            metrics.range_removed = !ranges.isEmpty
            metrics.cookie_removed = request.headers.keys.contains { $0.lowercased() == "cookie" }
            // Construct a fresh request; forward no original authentication, referer,
            // URL credentials or headers. The unbounded Range is removed, not a cap.
            var safe = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            safe.httpMethod = "GET"
            safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            safe.setValue("video/mp4,video/quicktime,application/octet-stream", forHTTPHeaderField: "Accept")
            return safe
        }
    }
    func stream(_ request: SignedRequest, options: TransportOptions) async throws -> (StreamHead, AsyncThrowingStream<StreamChunk, Error>) {
        let safe = try prepare(request, options)
        let head: StreamHead = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in start(safe, continuation) }
        } onCancel: { self.cancel() }
        // Unfolding avoids AsyncThrowingStream's continuation-based unbounded queue.
        // Our channel owns an explicit byte ceiling and backpressures the delegate.
        let chunks = AsyncThrowingStream<StreamChunk, Error>(unfolding: { [self] in
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if testConsumerDelay > 0 { try await Task.sleep(for: .milliseconds(testConsumerDelay)) }
                return try await withCheckedThrowingContinuation { next($0) }
            } onCancel: { self.cancel() }
        })
        return (head, chunks)
    }
    private func start(_ request: URLRequest, _ waiter: CheckedContinuation<StreamHead, Error>) {
        lock.synchronized {
            if let failure { waiter.resume(throwing: failure); return }
            headWaiter = waiter
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout * 3
            let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            let task = session.dataTask(with: request); self.task = task
            task.resume()
        }
    }
    private func next(_ waiter: CheckedContinuation<StreamChunk?, Error>) {
        lock.synchronized {
            if let failure { waiter.resume(throwing: failure); return }
            if !queue.isEmpty {
                let data = queue.removeFirst(); queueBytes -= data.count
                lock.broadcast()
                waiter.resume(returning: StreamChunk(data: data)); return
            }
            if finished { waiter.resume(returning: nil); return }
            guard bodyWaiter == nil else { waiter.resume(throwing: SafeStreamError.buffer); return }
            bodyWaiter = waiter; lock.broadcast()
        }
    }
    private func requestCancelLocked() {
        guard !metrics.cancel_requested else { return }
        metrics.cancel_requested = true; cancelTime = Date()
        metrics.accepted_at_cancel = metrics.accepted_bytes
        task?.cancel()
        lock.broadcast()
    }
    private func failLocked(_ error: SafeStreamError, requestCancel: Bool = true) {
        guard failure == nil && !finished else { return }
        failure = error; metrics.failure = error.rawValue
        metrics.discarded_buffered_bytes += queueBytes + prefix.count
        queue.removeAll(); queueBytes = 0; prefix.removeAll()
        if requestCancel { requestCancelLocked() }
        if let waiter = headWaiter { headWaiter = nil; waiter.resume(throwing: error) }
        if let waiter = bodyWaiter { bodyWaiter = nil; waiter.resume(throwing: error) }
    }
    func cancel() { lock.synchronized { failLocked(.cancelled) } }
    func awaitCompletion() async -> Bool {
        for _ in 0..<500 {
            if snapshot().completion_received { return true }
            // Separate from the cancelled caller's task; this does not fabricate a callback.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot().completion_received
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.synchronized {
            guard failure == nil, let http = response as? HTTPURLResponse else { failLocked(.network); completionHandler(.cancel); return }
            metrics.http_status = http.statusCode
            guard http.statusCode == 200 || http.statusCode == 206 else { failLocked(.status); completionHandler(.cancel); return }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map(String.init)?.lowercased() ?? ""
            guard ["video/mp4","video/quicktime","application/octet-stream"].contains(type),
                  (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity" else { failLocked(.type); completionHandler(.cancel); return }
            if let value = http.value(forHTTPHeaderField: "Content-Length") {
                guard let count = Int64(value), count >= 0 else { failLocked(.length); completionHandler(.cancel); return }
                declared = count; metrics.declared_bytes = count
                guard count <= Self.MAX_MEDIA_BYTES else { failLocked(.size); completionHandler(.cancel); return }
                guard count > 0 else { failLocked(.empty); completionHandler(.cancel); return }
            }
            if http.statusCode == 206 {
                guard let count = declared, http.value(forHTTPHeaderField: "Content-Range") == "bytes 0-\(count - 1)/\(count)" else { failLocked(.range); completionHandler(.cancel); return }
            } else if http.value(forHTTPHeaderField: "Content-Range") != nil { failLocked(.range); completionHandler(.cancel); return }
            let head = StreamHead(statusCode: http.statusCode, headers: ["Content-Type":type], contentLength:declared)
            if let waiter = headWaiter { headWaiter = nil; waiter.resume(returning: head) }
            completionHandler(.allow)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.synchronized {
            metrics.delegate_received_bytes += Int64(data.count)
            metrics.max_delegate_callback_bytes = max(metrics.max_delegate_callback_bytes, data.count)
            if metrics.cancel_requested {
                metrics.queued_callbacks_after_cancel += 1; metrics.bytes_after_cancel += Int64(data.count)
                return // Count queued bytes honestly, but never accept them.
            }
            guard !finished && failure == nil else { return }
            guard Int64(data.count) <= Self.MAX_MEDIA_BYTES - metrics.accepted_bytes else { failLocked(.budget); return }
            // URLSession controls callback size; suspend() does not prevent already
            // coalesced large callbacks. Keep only this framework-owned callback,
            // copy <=64 KiB pieces, and wait with the state lock RELEASED for space.
            // Cancellation broadcasts the condition, so it cannot deadlock here.
            var offset = 0
            while offset < data.count {
                let count = min(65536, data.count - offset)
                let deadline = Date().addingTimeInterval(timeout)
                while count + queueBytes + prefix.count > Self.MAX_BUFFER_BYTES && failure == nil && !metrics.cancel_requested {
                    metrics.backpressure_waits += 1
                    if !lock.wait(until: deadline) { failLocked(.timeout); break }
                }
                guard failure == nil && !metrics.cancel_requested && !finished else {
                    metrics.discarded_callback_bytes += data.count - offset; return
                }
                guard Int64(count) <= Self.MAX_MEDIA_BYTES - metrics.accepted_bytes else { failLocked(.budget); return }
                if let declared, metrics.accepted_bytes + Int64(count) > declared { failLocked(.length); return }
                var delivered = data.subdata(in: offset..<(offset + count)); offset += count
                metrics.accepted_bytes += Int64(count)
                if !prefixVerified {
                    prefix.append(delivered)
                    metrics.max_buffered_bytes = max(metrics.max_buffered_bytes, prefix.count + queueBytes)
                    if prefix.count < 12 { continue }
                    guard String(data: prefix.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else { failLocked(.type); return }
                    prefixVerified = true; delivered = prefix; prefix = Data()
                }
                if let waiter = bodyWaiter { bodyWaiter = nil; waiter.resume(returning: StreamChunk(data: delivered)) }
                else {
                    queue.append(delivered); queueBytes += delivered.count
                    metrics.max_buffered_bytes = max(metrics.max_buffered_bytes, queueBytes)
                }
                if metrics.accepted_bytes == Self.MAX_MEDIA_BYTES {
                    // Unknown-length boundary cannot establish full completion.
                    if declared == Self.MAX_MEDIA_BYTES { exactBoundary = true; requestCancelLocked() }
                    else { failLocked(.budget) }
                }
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.synchronized {
            metrics.completion_callbacks += 1
            guard !finished else { return }
            if failure == nil {
                if let error, !(exactBoundary && (error as NSError).code == NSURLErrorCancelled) {
                    failLocked((error as NSError).code == NSURLErrorTimedOut ? .timeout : .network, requestCancel: false)
                } else if !prefixVerified || metrics.accepted_bytes == 0 { failLocked(.empty, requestCancel: false) }
                else if let declared, metrics.accepted_bytes != declared { failLocked(.length, requestCancel: false) }
            }
            finished = true; metrics.completion_received = true; metrics.terminal_transitions += 1
            metrics.cancel_completed = metrics.cancel_requested
            if let cancelTime { metrics.cancel_to_completion_ms = Date().timeIntervalSince(cancelTime) * 1000 }
            if let waiter = headWaiter { headWaiter = nil; waiter.resume(throwing: failure ?? .network) }
            if let waiter = bodyWaiter {
                bodyWaiter = nil
                if let failure { waiter.resume(throwing: failure) } else { waiter.resume(returning: nil) }
            }
            self.task = nil; self.session = nil
        }
        session.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.synchronized { metrics.http_status = response.statusCode; failLocked(.redirect) }
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Normal HTTPS server trust uses the OS verifier; no client credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling,nil)
        } else { lock.synchronized { failLocked(.scope) }; completionHandler(.cancelAuthenticationChallenge,nil) }
    }
}
