import Foundation
import DouStudioKit

struct IntegrationResult: Codable {
    let id: String
    var status = "FAIL"
    var actual = "NOT_RUN"
    var expected: String
    var assertions: [String] = []
    var list_requests = 0
    var credential_present = false
    var extracted_count = 0
    var extracted_kind = "NOT_RUN"
    var downloader_success = false
    var validated_success = false
    var proof: MediaProof?
    var metrics: StreamMetrics?
    var written_bytes: Int64 = 0
    var partial_files = 0
    var cleanup_succeeded = false
    var second_request_rejected = false
    var expected_list_requests = 1
    var expected_media_requests = 0
    let STRICT_NETWORK_RECEIVE_LIMIT = "NOT_PROVEN"
    let REAL_DOUYIN_DOWNLOAD = "NOT_RUN"
    let HOST_ALLOWLIST_AUDIT = "BLOCKED"
}

enum DownloadIntegration {
    static let expected: [String:String] = [
        "INT-001":"PASS", "INT-002":"INDEX_REJECTED", "INT-003":"INDEX_REJECTED",
        "INT-004":"NON_VIDEO_REJECTED", "INT-005":"NON_VIDEO_REJECTED", "INT-006":"MEDIA_UNIT_COUNT_REJECTED",
        "INT-007":"INDEX_REJECTED", "INT-008":"HOST_SCOPE_REJECTED", "INT-009":"HOST_SCOPE_REJECTED",
        "INT-010":"NON_MEDIA_RESPONSE", "INT-011":"NON_MEDIA_RESPONSE", "INT-012":"MP4_CONTAINER_REJECTED",
        "INT-013":"MP4_CONTAINER_REJECTED", "INT-014":"MEDIA_DECODE_FAILED", "INT-015":"APPLICATION_BYTE_BUDGET_REACHED",
        "INT-016":"EMPTY_RESPONSE", "INT-017":"NETWORK_ERROR", "INT-018":"TIMEOUT", "INT-019":"CALLER_CANCELLED",
        "INT-020":"PASS", "INT-021":"PROFILE_REJECTED", "INT-022":"PASS", "INT-023":"ACCESS_RESTRICTED",
        "INT-024":"RATE_LIMITED", "INT-025":"SECOND_LIST_REQUEST_REJECTED", "INT-026":"REDIRECT_REJECTED",
        "INT-027":"CONSENT_REQUIRED", "INT-028":"SYNTHETIC_CREDENTIAL_MISSING"]
    static func category(_ error: Error) -> String {
        if let value = error as? IntegrationError { return value.rawValue }
        if let value = error as? SafeStreamError { return value.rawValue }
        if error is CancellationError { return "CALLER_CANCELLED" }
        return "SANITIZED_UNEXPECTED_ERROR"
    }
    @MainActor static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["INT_CASE"], let expected = expected[id], let text = env["INT_PORT"], let port = Int(text),
              (1024...65535).contains(port), let base = env["SAFE_MEDIA_ROOT"], let evidence = env["SAFE_EVIDENCE_ROOT"] else { exit(2) }
        let parent = URL(fileURLWithPath:base,isDirectory:true).standardizedFileURL
        let root = parent.appendingPathComponent(id + "-" + UUID().uuidString,isDirectory:true)
        guard root.deletingLastPathComponent() == parent, !FileManager.default.fileExists(atPath:root.path) else { exit(2) }
        var result = IntegrationResult(id:id,expected:expected)
        var transport: SafeStreamingTransport?
        var api: IntegrationListTransport?
        if ["INT-021","INT-022","INT-027","INT-028"].contains(id) { result.expected_list_requests = 0 }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            if id == "INT-022" {
                // Pure policy fixture: never creates a session or opens these URLs.
                let allow: Set<String> = ["fixture.invalid"]
                _ = try IntegrationPolicy.listComponents(URL(string:"https://www.douyin.com/aweme/v1/web/aweme/post/")!)
                for suffix in ["/aweme/v1/web/aweme/post","/aweme/v1/web/aweme/post/extra","/aweme/v1/web/aweme/poster/"] {
                    do { _ = try IntegrationPolicy.listComponents(URL(string:"https://www.douyin.com" + suffix)!); result.assertions.append("LIST_PATH_SCOPE_WIDENED") }
                    catch IntegrationError.host {}
                }
                try IntegrationPolicy.httpsHost(URL(string:"https://fixture.invalid/media")!,approved:allow)
                for value in ["http://fixture.invalid/media","https://sub.fixture.invalid/media","https://fixture.invalid.evil.invalid/media","https://user@fixture.invalid/media","https://fixture.invalid:8443/media","https://127.0.0.1/media"] {
                    do { try IntegrationPolicy.httpsHost(URL(string:value)!,approved:allow); result.assertions.append("HOST_POLICY_ACCEPTED_FORBIDDEN_FIXTURE") }
                    catch IntegrationError.host {} catch { result.assertions.append("UNEXPECTED_POLICY_ERROR") }
                }
                do { try IntegrationPolicy.httpsHost(URL(string:"https://fixture.invalid/media")!,approved:IntegrationPolicy.auditedProductionHosts); result.assertions.append("PRODUCTION_ALLOWLIST_OPENED") }
                catch IntegrationError.host {}
                result.actual = "PASS"
            } else {
                let profile = id == "INT-021" ? "https://www.douyin.com/user/fixture_user?unexpected=1" : "https://www.douyin.com/user/fixture_user"
                let userID = try IntegrationPolicy.profile(profile,authorized:id != "INT-027",credentialPresent:id != "INT-028")
                let list = IntegrationListTransport(port:port,caseID:id); api = list
                let configuration = KernelConfiguration(downloadRoot:root.path,storageTargets:[],pageSize:18,maxPages:1,maxConcurrency:1,maxRetry:0,timeout:5,preferOriginalQuality:false)
                let client = try await DouyinClient(configuration:configuration,cookie:IntegrationListTransport.syntheticCookie,transport:list,logger:.disabled)
                let endpoints = await client.endpoints
                let timeline = try await endpoints.accountTimeline(secUid:userID,tab:.post,page:PageRequest(count:18,maxPages:1,cursor:0))
                if id == "INT-025" { _ = try await endpoints.accountTimeline(secUid:userID,tab:.post,page:PageRequest(count:18,maxPages:1,cursor:0)) }
                let extractor = DouyinExtractor(options:ExtractionOptions(preferOriginalQuality:false))
                var works = timeline.works.map { extractor.work(from:$0,collectionTime:"") }
                result.extracted_count = works.count; result.extracted_kind = works.first?.kind.rawValue ?? "EMPTY"
                // Explicit invalid-model fixture: production extracted records are never mutated.
                if id == "INT-006", !works.isEmpty { works[0].downloads += works[0].downloads }
                let index = id == "INT-002" ? -1 : id == "INT-003" ? works.count : 0
                let selected = try IntegrationPolicy.select(works,index:index)
                let url = try IntegrationPolicy.fixtureURL(selected,port:port,caseID:id)
                result.expected_media_requests = 1
                let streaming = try SafeStreamingTransport(loopbackURL:url,timeout:id == "INT-018" ? 1 : 10); transport = streaming
                // Authentication is scoped to the list client. The media session is EMPTY.
                let downloader = Downloader(transport:streaming,session:SessionStore(cookie:"",maxRetry:0),layout:DownloadLayout(root:root),logger:.disabled)
                let operation = Task {
                    try await withTaskCancellationHandler {
                        try await downloader.download(work:selected,progress:{ _ in })
                    } onCancel: { streaming.cancel() }
                }
                if id == "INT-019" {
                    for _ in 0..<300 {
                        if streaming.snapshot().accepted_bytes > 0 { break }
                        try await Task.sleep(for:.milliseconds(10))
                    }
                    operation.cancel()
                }
                let outcome: DownloadOutcome
                do { outcome = try await operation.value }
                catch { streaming.cancel(); _ = await streaming.awaitCompletion(); throw error }
                guard await streaming.awaitCompletion() else { throw IntegrationError.outcome }
                guard case .downloaded(let files) = outcome, files.count == 1,
                      files[0].standardizedFileURL.path.hasPrefix(root.path + "/") else { throw IntegrationError.outcome }
                result.downloader_success = true
                result.proof = try await IntegrationMedia.validate(files[0],accepted:streaming.snapshot().accepted_bytes)
                result.validated_success = true
                if result.proof?.decoded_frames != 30 { result.assertions.append("FIXTURE_FRAME_COUNT") }
                if id == "INT-020" {
                    var other = selected; other.id += "2"
                    do { _ = try await downloader.download(work:other,progress:{ _ in }) }
                    catch { result.second_request_rejected = (error as? SafeStreamError) == .second }
                    if !result.second_request_rejected { result.assertions.append("SECOND_MEDIA_ACCEPTED") }
                }
                result.actual = "PASS"
            }
        } catch {
            result.actual = category(error)
            if let transport { transport.cancel(); if transport.snapshot().stream_calls > 0 { _ = await transport.awaitCompletion() } }
        }
        if let api { result.list_requests = await api.requests; result.credential_present = await api.credentialPresent }
        if let transport {
            let m = transport.snapshot(); result.metrics = m
            if m.accepted_bytes > SafeStreamingTransport.MAX_MEDIA_BYTES { result.assertions.append("APPLICATION_BUDGET") }
            if m.stream_calls != 1 || m.buffered_send_calls != 0 { result.assertions.append("STREAMING_PATH") }
            if !m.completion_received || m.terminal_transitions != 1 { result.assertions.append("SINGLE_TERMINAL_CALLBACK") }
            if m.cancel_requested && (!m.cancel_completed || m.accepted_bytes != m.accepted_at_cancel) { result.assertions.append("CANCEL_COMPLETION") }
            if m.cookie_removed { result.assertions.append("MEDIA_SESSION_WAS_NOT_EMPTY") }
        }
        let files = ControlledTests.files(root)
        result.written_bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
        result.partial_files = files.filter { $0.pathExtension == "part" }.count
        if let m = result.metrics, result.written_bytes > m.accepted_bytes { result.assertions.append("WRITTEN_BUDGET") }
        if result.actual != expected { result.assertions.append("EXPECTED_FIXED_ERROR_CATEGORY") }
        if expected != "PASS" && result.validated_success { result.assertions.append("INVALID_MEDIA_MARKED_PASS") }
        if result.list_requests != result.expected_list_requests { result.assertions.append("LIST_REQUEST_LIMIT") }
        do {
            guard root.standardizedFileURL.deletingLastPathComponent() == parent else { throw IntegrationError.cleanup }
            try FileManager.default.removeItem(at:root)
            result.cleanup_succeeded = !FileManager.default.fileExists(atPath:root.path)
        } catch { result.assertions.append("WORKSPACE_CLEANUP") }
        if !result.cleanup_succeeded { result.assertions.append("RESIDUAL_WORKSPACE") }
        result.status = result.assertions.isEmpty ? "PASS" : "FAIL"
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(result).write(to:URL(fileURLWithPath:evidence).appendingPathComponent(id + ".json"),options:.atomic)
        } catch { exit(2) }
        print("\(id) \(result.status) \(result.actual)")
        exit(result.status == "PASS" ? 0 : 1)
    }
}
