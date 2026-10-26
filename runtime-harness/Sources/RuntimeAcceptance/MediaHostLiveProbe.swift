import Foundation
import DouStudioKit

// URLs live only in local variables. None of the diagnostic types can carry a URL/body/ID.
struct LiveProbeObservation: Codable, Sendable {
    var host: String
    var request_count = 0
    var http_status: Int?
    var content_type = "NOT_RECEIVED"
    var content_range_valid = false
    var content_length_one = false
    var redirect_host: String?
    var redirect_target_rejected = false
    var delegate_received_bytes = 0
    var accepted_bytes = 0
    var cancel_requested = false
    var cancel_completed = false
    var completion_callbacks = 0
    var result = "NOT_RUN"
    var authentication_headers_sent = false
    var range_zero_only = true
    var approved = false
}

enum LiveProbePolicy {
    static let hosts: Set<String> = ["sf11-cdn-tos.douyinstatic.com", "www.douyin.com"]
    static func allowed(_ value: String) -> Bool {
        let r = MediaHostAudit.describe(value,id:"PROBE",alias:"PROBE",role:"video_playback",field:"selected",selected:true)
        return r.url_shape == "CANDIDATE_ONLY" && hosts.contains(r.normalized_host ?? "")
    }
    // Reuse the existing bounded collector and exact original selection/source association.
    static func select(_ items: [JSONNode]) throws -> [(String, URL)] {
        let collection = SelectedHostEvidence.collect(items)
        guard collection.complete else { throw AuthPreflightError.response }
        var chosen: [(String, URL)] = []
        var seen: Set<String> = []
        let extractor = DouyinExtractor(options:ExtractionOptions(preferOriginalQuality:false))
        for item in items {
            let work = extractor.work(from:item,collectionTime:"")
            guard work.kind == .video, work.downloads.count == 1, case .media(let address) = work.downloads[0],
                  allowed(address), let url = URL(string:address), let host = url.host?.lowercased(),
                  !seen.contains(host),
                  SelectedHostEvidence.associate(item,selected:address,workRef:"PROBE")?.selection_match == true else { continue }
            seen.insert(host); chosen.append((host,url))
        }
        guard !chosen.isEmpty else { throw AuthPreflightError.scope }
        return chosen
    }
}

// One data task, no downloader and no buffered transport fallback. SafeStreamingTransport is unchanged:
// its MP4 prefix and 100 MiB contract are deliberately not repurposed for a one-byte diagnostic.
final class LiveProbeTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var observed: LiveProbeObservation
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<LiveProbeObservation, Never>?
    private var used = false
    private var callerCancelled = false
    init(host: String) { observed = LiveProbeObservation(host:host) }

    func run(_ url: URL, fixture: Bool = false) async -> LiveProbeObservation {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                guard !used else {
                    var refused = LiveProbeObservation(host:observed.host); refused.result = "SINGLE_REQUEST_LIMIT"
                    continuation.resume(returning:refused); return
                }
                used = true
                let local = url.scheme == "http" && url.host == "127.0.0.1" && url.port != nil && url.user == nil && url.password == nil
                guard (fixture ? local : (LiveProbePolicy.allowed(url.absoluteString) && url.host?.lowercased() == observed.host)) else {
                    observed.result = "REQUEST_SCOPE_REJECTED"; continuation.resume(returning:observed); return
                }
                guard !callerCancelled else {
                    observed.result = "CALLER_CANCELLED_BEFORE_REQUEST"; continuation.resume(returning:observed); return
                }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil; config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.connectionProxyDictionary = [:]
                config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
                config.httpMaximumConnectionsPerHost = 1
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration:config,delegate:self,delegateQueue:queue)
                self.session = session
                var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
                request.httpMethod = "GET"
                // Build from scratch: no client/session headers, Cookie, Authorization, Referer or Range continuation.
                request.allHTTPHeaderFields = ["Range":"bytes=0-0", "Accept":"video/*", "Accept-Encoding":"identity"]
                observed.authentication_headers_sent = (request.allHTTPHeaderFields ?? [:]).keys.contains {
                    ["cookie","authorization","proxy-authorization","x-api-key"].contains($0.lowercased())
                }
                let task = session.dataTask(with:request); self.task = task
                observed.request_count = 1; task.resume()
            }
        } onCancel: {
            self.lock.lock(); defer { self.lock.unlock() }
            self.callerCancelled = true
            if self.task != nil { self.stop("CALLER_CANCELLED") }
        }
    }
    // Caller holds lock. Wait for didCompleteWithError; cancel() itself is never completion evidence.
    private func stop(_ reason: String) {
        if !observed.cancel_requested {
            observed.result = reason; observed.cancel_requested = true; task?.cancel()
        }
    }
    private func redirect(_ response: HTTPURLResponse, target: URL?) {
        observed.http_status = response.statusCode
        if let target {
            let r = MediaHostAudit.describe(target.absoluteString,id:"REDIRECT",alias:"REDIRECT",role:"video_playback",field:"target",selected:false)
            if r.url_shape == "CANDIDATE_ONLY" { observed.redirect_host = r.normalized_host }
            else { observed.redirect_target_rejected = true }
        } else { observed.redirect_target_rejected = true }
        stop("HTTP_REDIRECT_NOT_FOLLOWED")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirect(response,target:request.url); lock.unlock()
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Default TLS trust evaluation is required. HTTP authentication never consults credential stores.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling,nil)
        } else {
            lock.lock(); stop("AUTH_CHALLENGE_REJECTED"); lock.unlock()
            completionHandler(.cancelAuthenticationChallenge,nil)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !observed.cancel_requested, let http = response as? HTTPURLResponse else {
            stop("INVALID_RESPONSE"); completionHandler(.cancel); return
        }
        observed.http_status = http.statusCode
        if (300..<400).contains(http.statusCode) {
            let target = http.value(forHTTPHeaderField:"Location").flatMap { URL(string:$0,relativeTo:http.url)?.absoluteURL }
            redirect(http,target:target); completionHandler(.cancel); return
        }
        let type = (http.value(forHTTPHeaderField:"Content-Type") ?? "").lowercased().split(separator:";").first.map(String.init) ?? ""
        observed.content_type = type.hasPrefix("video/") ? "VIDEO" : (type.contains("html") ? "HTML" : (type.contains("json") ? "JSON" : "OTHER"))
        let range = http.value(forHTTPHeaderField:"Content-Range") ?? ""
        if range.range(of:"^bytes 0-0/[1-9][0-9]{0,18}$",options:.regularExpression) != nil {
            observed.content_range_valid = Int64(range.split(separator:"/").last ?? "") != nil
        }
        let length = http.value(forHTTPHeaderField:"Content-Length")
        observed.content_length_one = length == "1"
        let encoding = (http.value(forHTTPHeaderField:"Content-Encoding") ?? "identity").lowercased()
        let reason: String?
        switch http.statusCode {
        case 200: reason = "RANGE_IGNORED_200"
        case 403: reason = "ACCESS_RESTRICTED"
        case 429: reason = "RATE_LIMITED"
        case 206:
            if observed.content_type != "VIDEO" { reason = "NON_VIDEO_RESPONSE" }
            else if !observed.content_range_valid || (length != nil && length != "1") || encoding != "identity" { reason = "INVALID_RANGE_RESPONSE" }
            else { reason = nil }
        default: reason = "HTTP_STATUS_REJECTED"
        }
        if let reason { stop(reason); completionHandler(.cancel) }
        else { observed.result = "AWAITING_ONE_BYTE"; completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        observed.delegate_received_bytes += data.count // Includes callbacks arriving after cancellation.
        guard !observed.cancel_requested else { return }
        guard observed.result == "AWAITING_ONE_BYTE", data.count == 1, observed.accepted_bytes == 0 else {
            stop("BODY_BUDGET_EXCEEDED"); return
        }
        observed.accepted_bytes = 1 // Count only; do not retain or write even the single byte.
        stop("VIDEO_RANGE_206_ONE_BYTE")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        observed.completion_callbacks += 1
        observed.cancel_completed = observed.cancel_requested
        // A late callback may arrive after the one-byte budget triggered cancellation. Count it,
        // but never call that additional payload an accepted or verified video response.
        if observed.result == "VIDEO_RANGE_206_ONE_BYTE" && observed.delegate_received_bytes > 1 {
            observed.result = "BODY_BUDGET_EXCEEDED"
        }
        if !observed.cancel_requested { observed.result = error == nil ? "EMPTY_OR_INCOMPLETE_BODY" : "NETWORK_OR_TIMEOUT_ERROR" }
        let result = observed, waiter = continuation
        continuation = nil; self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate(); waiter?.resume(returning:result)
    }
}

@MainActor enum MediaHostLiveProbe {
    static func publish(_ observations: [LiveProbeObservation], _ list: AuthObservation, _ failure: String?, _ folder: URL) throws {
        try MediaHostAudit.write(observations,"host-observations.json",folder)
        try MediaHostAudit.write(observations,"response-header-evidence.json",folder)
        try MediaHostAudit.write(observations.filter { $0.result == "HTTP_REDIRECT_NOT_FOLLOWED" },"redirect-evidence.json",folder)
        try MediaHostAudit.write(["authentication_headers_sent":observations.contains { $0.authentication_headers_sent },"fresh_ephemeral_media_sessions":true],"credential-isolation-results.json",folder)
        try MediaHostAudit.write(["worklist":list.request_count,"media":observations.reduce(0) { $0 + $1.request_count }],"request-count-results.json",folder)
        try MediaHostAudit.write([String](),"approved-hosts.json",folder)
        struct Summary: Codable {
            let worklist: AuthObservation
            let failure_category: String?
            let media_probe_completed: Bool
            let REAL_MEDIA_PROBE: String
            let REAL_VIDEO_DOWNLOAD = "NOT_RUN"
            let PRODUCTION_ALLOWLIST = "EMPTY"
            let APPROVED_HOSTS = 0
            let STRICT_NETWORK_RECEIVE_LIMIT = "NOT_PROVEN"
            let VIDEO_CONTENT_INTEGRITY = "NOT_VERIFIED_ONE_BYTE_ONLY"
        }
        try MediaHostAudit.write(Summary(worklist:list,failure_category:failure,media_probe_completed:failure == nil && !observations.isEmpty,
            REAL_MEDIA_PROBE:observations.isEmpty ? "NOT_RUN" : (failure == nil ? "OBSERVATION_COMPLETED" : "STOPPED")),"probe-summary.json",folder)
    }
    static func expectedObservation(_ o: LiveProbeObservation) -> Bool {
        ["VIDEO_RANGE_206_ONE_BYTE","HTTP_REDIRECT_NOT_FOLLOWED"].contains(o.result) && o.completion_callbacks == 1 && o.cancel_completed
    }
    static func run(_ env: [String:String]) async throws -> Bool {
        guard let path = env["PROBE_EVIDENCE_DIR"] else { return false }
        var observations: [LiveProbeObservation] = [], list = AuthObservation(), failure: String?
        var observer: AuthPreflightTransport?
        do {
            // Wrapper verifies build+offline gates before this explicitly authorized entry.
            guard env["PROBE_OFFLINE_VERIFIED"] == "true" else { throw AuthPreflightError.scope }
            let input = try AuthPreflightInput.validate(consent:env["PROBE_CONSENT"] == "true",cookie:env["DOUYIN_COOKIE"] ?? "",profile:env["PROBE_PROFILE"] ?? "")
            let transport = AuthPreflightTransport(input:input,base:URLSessionTransport()); observer = transport
            let config = KernelConfiguration(storageTargets:[],pageSize:18,maxPages:1,maxConcurrency:1,maxRetry:0,timeout:30,preferOriginalQuality:false)
            let client = try await DouyinClient(configuration:config,cookie:input.cookie,transport:transport,logger:.disabled)
            let endpoints = await client.endpoints
            let page = try await endpoints.accountTimeline(secUid:input.userID,tab:.post,page:PageRequest(count:18,maxPages:1,cursor:0))
            let selected = try LiveProbePolicy.select(page.works)
            for (host,url) in selected {
                let result = await LiveProbeTask(host:host).run(url)
                observations.append(result)
                // Anomalies stop the entire run, including any second host. Redirect is a completed diagnostic, never followed.
                if !expectedObservation(result) { failure = "MEDIA_PROBE_STOPPED"; break }
            }
        } catch { failure = (error as? AuthPreflightError)?.rawValue ?? "SANITIZED_PROBE_ERROR" }
        if let observer { list = await observer.snapshot() }
        try publish(observations,list,failure,URL(fileURLWithPath:path,isDirectory:true))
        return failure == nil && !observations.isEmpty
    }
}
