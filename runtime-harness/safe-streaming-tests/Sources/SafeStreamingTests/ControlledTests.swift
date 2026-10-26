import Foundation
import CryptoKit
import DouStudioKit

struct ControlledResult: Codable {
    let id: String
    var status = "FAIL"
    var expected: String
    var actual = "NOT_RUN"
    var metrics = StreamMetrics()
    var written_bytes: Int64 = 0
    var partial_files_before_cleanup = 0
    var downloaded_files_before_cleanup = 0
    var cleanup_succeeded = false
    var residual_files_after_cleanup = 0
    var file_hash_repeatable = false
    var file_sha256: String?
    var downloader_reported_success = false
    var second_rejected = false
    var buffered_fallback_rejected = false
    var failed_assertions: [String] = []
    var expected_requests = 1
    var post_cancel_callback_observation = "NOT_OBSERVED"
    let strict_network_receive_limit = "NOT_PROVEN"
    let real_douyin_download = "NOT_RUN"
}

@main struct ControlledTests {
    static let cases = (1...28).map { String(format:"ST-%03d",$0) }
    static let failureCases: Set<String> = ["ST-002","ST-003","ST-007","ST-009","ST-010","ST-011","ST-012","ST-013","ST-014","ST-015","ST-016","ST-022","ST-023","ST-024","ST-026","ST-027","ST-028"]
    static func hash(_ url: URL) throws -> String {
        try StreamFileTools.hash(url)
    }
    static func files(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true }
    }
    static func work(_ url: URL, id: String = "100") -> DouyinWork {
        DouyinWork(id:id,desc:"controlled-fixture",createTimestamp:1,createTime:"fixture",kind:.video,nickname:"fixture",downloads:[.media(url:url.absoluteString)])
    }
    @MainActor static func main() async {
        if Array(CommandLine.arguments.dropFirst()) == ["--integration-fixture"] { await IntegrationMedia.generateMain(); return }
        if Array(CommandLine.arguments.dropFirst()) == ["--integration-case"] { await DownloadIntegration.run(); return }
        let env = ProcessInfo.processInfo.environment
        guard let id = env["SAFE_CASE"], cases.contains(id), let portText = env["SAFE_PORT"], let port = Int(portText), port >= 1024,
              let base = env["SAFE_MEDIA_ROOT"], let evidence = env["SAFE_EVIDENCE_ROOT"],
              let url = URL(string:"http://127.0.0.1:\(port)/\(id)") else { exit(2) }
        var result = ControlledResult(id:id, expected:failureCases.contains(id) ? "REJECT_AND_CLEAN" : "COMPLETE_AND_CLEAN")
        let root = URL(fileURLWithPath:base,isDirectory:true).appendingPathComponent(id + "-" + UUID().uuidString,isDirectory:true)
        let parent = URL(fileURLWithPath:base,isDirectory:true).standardizedFileURL
        guard root.standardizedFileURL.deletingLastPathComponent() == parent, !FileManager.default.fileExists(atPath:root.path) else { exit(2) }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let transport: SafeStreamingTransport
            if id == "ST-027" { transport = SafeStreamingTransport(extractedMediaURL:url,verifiedMediaHosts:["127.0.0.1"]) }
            else { transport = try SafeStreamingTransport(loopbackURL:url,timeout:id == "ST-014" ? 1 : 15,consumerDelayMilliseconds:id == "ST-016" ? 1000 : 0) }
            let session = SessionStore(cookie:id == "ST-020" ? "synthetic_fixture=not_a_credential" : "",maxRetry:0)
            let downloader = Downloader(transport:transport,session:session,layout:DownloadLayout(root:root),logger:.disabled)
            if ["ST-026","ST-027","ST-028"].contains(id) {
                result.expected_requests = 0
                let headers = id == "ST-026" ? ["Authorization":"synthetic"] : id == "ST-028" ? ["Range":"bytes=64-"] : [:]
                do {
                    _ = try await transport.stream(SignedRequest(method:.get,baseURL:url.absoluteString,query:"",headers:headers),options:TransportOptions())
                    result.actual = "UNEXPECTED_SCOPE_ACCEPTANCE"
                } catch { result.actual = (error as? SafeStreamError)?.rawValue ?? "REDACTED_ERROR" }
            } else {
                let operation = Task {
                    try await withTaskCancellationHandler {
                        try await downloader.download(work:work(url),progress:{ _ in })
                    } onCancel: { transport.cancel() }
                }
                if ["ST-015","ST-016","ST-017"].contains(id) {
                    for _ in 0..<300 {
                        let state = transport.snapshot()
                        if id == "ST-016" ? state.max_buffered_bytes > 0 : state.accepted_bytes > 0 { break }
                        try await Task.sleep(for:.milliseconds(10))
                    }
                    if id == "ST-017" {
                        do { _ = try await downloader.download(work:work(url,id:"200"),progress:{ _ in }) }
                        catch { result.second_rejected = (error as? SafeStreamError) == .second }
                    } else { operation.cancel() }
                }
                do {
                    let outcome = try await operation.value
                    if case .downloaded(let paths) = outcome, paths.count == 1 {
                        result.downloader_reported_success = true; result.actual = "DOWNLOADED"
                        let first = try hash(paths[0]), second = try hash(paths[0])
                        result.file_hash_repeatable = first == second; result.file_sha256 = first
                    } else { result.actual = "UNEXPECTED_DOWNLOAD_OUTCOME" }
                } catch { result.actual = (error as? SafeStreamError)?.rawValue ?? (error is CancellationError ? "CALLER_CANCELLED" : "REDACTED_ERROR") }
                _ = await transport.awaitCompletion()
                if id == "ST-018" {
                    do { _ = try await downloader.download(work:work(url,id:"201"),progress:{ _ in }) }
                    catch { result.second_rejected = (error as? SafeStreamError) == .second }
                }
                if id == "ST-019" {
                    do { _ = try await transport.send(SignedRequest(method:.get,baseURL:url.absoluteString,query:"",headers:[:]),options:TransportOptions()) }
                    catch { result.buffered_fallback_rejected = (error as? SafeStreamError) == .buffered }
                }
            }
            result.metrics = transport.snapshot()
            if result.metrics.queued_callbacks_after_cancel > 0 { result.post_cancel_callback_observation = "OBSERVED_AND_REJECTED" }
            let written = files(root)
            result.written_bytes = written.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
            result.partial_files_before_cleanup = written.filter { $0.pathExtension == "part" }.count
            result.downloaded_files_before_cleanup = written.filter { $0.pathExtension != "part" }.count
            func check(_ condition: Bool,_ name: String) { if !condition { result.failed_assertions.append(name) } }
            let m = result.metrics
            check(m.accepted_bytes <= SafeStreamingTransport.MAX_MEDIA_BYTES,"accepted_budget")
            check(result.written_bytes <= m.accepted_bytes,"written_not_above_accepted")
            check(m.max_buffered_bytes <= SafeStreamingTransport.MAX_BUFFER_BYTES,"bounded_channel")
            check(m.stream_calls == 1,"single_stream_call")
            check(m.buffered_send_calls == (id == "ST-019" ? 1 : 0),"no_buffered_fallback")
            if result.expected_requests == 1 {
                check(m.completion_received && m.completion_callbacks == 1 && m.terminal_transitions == 1,"exactly_one_real_terminal_callback")
                check(m.range_removed,"original_unbounded_range_removed")
            }
            if m.cancel_requested {
                check(m.cancel_completed,"cancel_completion_callback")
                check(m.accepted_at_cancel == m.accepted_bytes,"no_accept_after_cancel")
                check((m.cancel_to_completion_ms ?? 99999) < 5000,"cancel_within_five_seconds")
            }
            if failureCases.contains(id) {
                check(!result.downloader_reported_success,"failure_not_success")
                check(result.downloaded_files_before_cleanup == 0,"failure_has_no_final_file")
            } else {
                check(result.downloader_reported_success && result.file_hash_repeatable,"original_downloader_success_and_repeatable_hash")
                check(result.written_bytes == m.accepted_bytes && result.written_bytes > 0,"complete_written_bytes")
            }
            let expectedErrors: [String:Set<String>] = [
                "ST-002":["EMPTY_RESPONSE"],"ST-003":["DECLARED_LENGTH_OVER_BUDGET"],"ST-007":["APPLICATION_BYTE_BUDGET_REACHED"],
                "ST-009":["REDIRECT_REJECTED"],"ST-010":["REDIRECT_REJECTED"],"ST-011":["NON_MEDIA_RESPONSE"],"ST-012":["NON_MEDIA_RESPONSE"],
                "ST-013":["NETWORK_ERROR","LENGTH_MISMATCH"],"ST-014":["TIMEOUT"],"ST-015":["CALLER_CANCELLED"],"ST-016":["CALLER_CANCELLED"],
                "ST-022":["INCOMPLETE_RANGE_REJECTED"],"ST-023":["HTTP_STATUS_REJECTED"],"ST-024":["NON_MEDIA_RESPONSE"],
                "ST-026":["REQUEST_SCOPE_REJECTED"],"ST-027":["REQUEST_SCOPE_REJECTED"],"ST-028":["REQUEST_SCOPE_REJECTED"]]
            if let expected = expectedErrors[id] { check(expected.contains(result.actual),"specific_failure_category") }
            if ["ST-003","ST-007","ST-009","ST-010","ST-015","ST-016"].contains(id) { check(m.cancel_requested,"underlying_cancel_requested") }
            if id == "ST-003" { check(m.accepted_bytes == 0,"oversize_header_accepts_no_body") }
            if id == "ST-005" { check(result.written_bytes == SafeStreamingTransport.MAX_MEDIA_BYTES - 1,"below_boundary_full_payload") }
            if id == "ST-006" { check(result.written_bytes == SafeStreamingTransport.MAX_MEDIA_BYTES && m.cancel_requested && m.cancel_completed,"exact_boundary_full_payload_and_cancel") }
            if id == "ST-016" {
                check(m.discarded_buffered_bytes > 0,"queued_bytes_discarded_on_cancel")
                check(m.failure == SafeStreamError.cancelled.rawValue,"caller_cancel_is_transport_root_cause")
            }
            if ["ST-017","ST-018"].contains(id) { check(result.second_rejected && m.rejected_second_requests == 1,"second_request_rejected") }
            if id == "ST-019" { check(result.buffered_fallback_rejected,"buffered_path_hard_rejection") }
            if id == "ST-020" { check(m.cookie_removed,"synthetic_cookie_stripped") }
        } catch { result.failed_assertions.append("TEST_INFRASTRUCTURE_ERROR") }
        // Scope-owned workspace only, after the downloader exits and completion is observed.
        do {
            guard root.standardizedFileURL.deletingLastPathComponent() == parent else { throw SafeStreamError.scope }
            if FileManager.default.fileExists(atPath:root.path) { try FileManager.default.removeItem(at:root) }
            result.cleanup_succeeded = !FileManager.default.fileExists(atPath:root.path)
            result.residual_files_after_cleanup = files(root).count
        } catch { result.failed_assertions.append("CLEANUP_FAILED") }
        if !result.cleanup_succeeded { result.failed_assertions.append("PARTIAL_CLEANUP_NOT_VERIFIED") }
        result.status = result.failed_assertions.isEmpty ? "PASS" : "FAIL"
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(result).write(to:URL(fileURLWithPath:evidence).appendingPathComponent(id + ".json"),options:.atomic)
        } catch { exit(2) }
        print("\(id) \(result.status) received=\(result.metrics.delegate_received_bytes) accepted=\(result.metrics.accepted_bytes) written=\(result.written_bytes) cancel=\(result.metrics.cancel_requested)/\(result.metrics.cancel_completed)")
        exit(result.status == "PASS" ? 0 : 1)
    }
}
