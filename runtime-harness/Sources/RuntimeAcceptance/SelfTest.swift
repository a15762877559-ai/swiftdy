import Foundation
import CoreFoundation
import DouStudioKit

/// Each send consumes an in-memory response or throws. No real network calls.
private actor FixtureTransport: HTTPTransport {
    var responses: [HTTPResponse]
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        guard !responses.isEmpty, !options.followRedirects else {
            throw AcceptanceStop(code: "FIXTURE_EXHAUSTED", blocked: false)
        }
        return responses.removeFirst()
    }
}

private struct OfflineMismatch: Error {
    let actual: String // Only fixed fixture summaries, never external input.
}
struct OfflineCaseResult: Codable {
    let id: String
    let name: String
    let function: String
    let status: String
    let errorCategory: String
    let expected: String
    let actual: String
}

@MainActor
enum SelfTest {
    static let first = #"{"status_code":0,"aweme_list":[{"aweme_id":"1234567890123456789","desc":"fixture","create_time":1}],"max_cursor":900,"has_more":1}"#
    static let last = #"{"status_code":0,"aweme_list":[],"max_cursor":800,"has_more":0}"#
    static func request(_ cursor: Int) -> SignedRequest {
        SignedRequest(method: .get, baseURL: "https://www.douyin.com/aweme/v1/web/aweme/post/",
                      query: "max_cursor=\(cursor)", headers: [:])
    }
    static func response(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8), finalURL: nil)
    }
    static func check(_ value: Bool, _ actual: String) throws {
        if !value { throw OfflineMismatch(actual: actual) }
    }
    static func expectStop(_ code: String?, blocked: Bool? = nil,
                           operation: @MainActor () async throws -> Void) async throws -> String {
        do { try await operation() }
        catch let stop as AcceptanceStop {
            let actual = "code=\(stop.code);blocked=\(stop.blocked)"
            try check((code == nil || stop.code == code) && (blocked == nil || stop.blocked == blocked), actual)
            return actual
        }
        throw OfflineMismatch(actual: "returned_success_without_expected_exception")
    }
    static func twoPages() async throws -> Observation {
        let observer = ObservingTransport(base: FixtureTransport([response(first), response(last)]))
        _ = try await observer.send(request(0), options: TransportOptions())
        _ = try await observer.send(request(900), options: TransportOptions())
        return await observer.snapshot()
    }
    static func run() async throws -> Bool {
        var results: [OfflineCaseResult] = []
        func runCase(_ id: String, _ name: String, _ function: String, _ expected: String,
                     body: @MainActor () async throws -> String) async {
            print("BEGIN \(id) | \(name) | function=\(function)")
            let result: OfflineCaseResult
            do {
                result = OfflineCaseResult(id: id, name: name, function: function, status: "PASS",
                    errorCategory: "NONE", expected: expected, actual: try await body())
            } catch {
                let category: String
                let actual: String
                if let mismatch = error as? OfflineMismatch {
                    category = "ASSERTION_MISMATCH"; actual = mismatch.actual
                } else if let stop = error as? AcceptanceStop {
                    category = "UNEXPECTED_ACCEPTANCE_STOP"; actual = "code=\(stop.code);blocked=\(stop.blocked)"
                } else {
                    category = "UNEXPECTED_ERROR_REDACTED"; actual = "exception_details_omitted"
                }
                result = OfflineCaseResult(id: id, name: name, function: function, status: "FAIL",
                    errorCategory: category, expected: expected, actual: actual)
            }
            results.append(result)
            if let data = try? JSONEncoder().encode(result), let line = String(data: data, encoding: .utf8) { print(line) }
        }
        // OFF-001..007 retain the original fixtures and assertions.
        await runCase("OFF-001", "Profile identifier", "LinkParser.parse", "user identifier matches offline_fixture") {
            guard let link = LinkParser().parse("https://www.douyin.com/user/offline_fixture"),
                  case .user(let id, _) = link.target else { throw OfflineMismatch(actual: "not_user_target") }
            try check(id == "offline_fixture", "identifier_matches=\(id == "offline_fixture");length=\(id.count)")
            return "identifier_matches=true"
        }
        await runCase("OFF-002", "Server cursor propagation", "ObservingTransport.send/observePage", "pages=2;second_cursor=900") {
            let result = try await twoPages()
            let actual = "pages=\(result.pages.count);second_cursor=\(result.pages.dropFirst().first?.requestCursor ?? "missing")"
            try check(result.pages.count == 2 && result.pages[1].requestCursor == "900", actual)
            return actual
        }
        await runCase("OFF-003", "Terminal state and fields", "ObservingTransport.observePage", "hasMore=false;fields=1") {
            let result = try await twoPages()
            let actual = "hasMore=\(String(describing: result.pages.last?.hasMore));fields=\(result.fields.count)"
            try check(result.pages.last?.hasMore == false && result.fields.count == 1, actual)
            return actual
        }
        await runCase("OFF-004", "Repeated cursor rejection", "ObservingTransport.observePage", "CURSOR_STALLED_OR_CYCLIC") {
            let observer = ObservingTransport(base: FixtureTransport([response(first), response(first)]))
            _ = try await observer.send(request(0), options: TransportOptions())
            return try await expectStop("CURSOR_STALLED_OR_CYCLIC") {
                _ = try await observer.send(request(900), options: TransportOptions())
            }
        }
        await runCase("OFF-005", "HTTP access rejection", "ObservingTransport.send", "throws blocked=true") {
            let observer = ObservingTransport(base: FixtureTransport([response("", status: 403)]))
            return try await expectStop(nil, blocked: true) { _ = try await observer.send(request(0), options: TransportOptions()) }
        }
        await runCase("OFF-006", "HTML challenge rejection", "ObservingTransport.observePage", "throws blocked=true") {
            let observer = ObservingTransport(base: FixtureTransport([response("<html>challenge</html>")]))
            return try await expectStop(nil, blocked: true) { _ = try await observer.send(request(0), options: TransportOptions()) }
        }
        await runCase("OFF-007", "Request cursor mismatch", "ObservingTransport.sendChecked", "REQUEST_CURSOR_MISMATCH") {
            let observer = ObservingTransport(base: FixtureTransport([]))
            return try await expectStop("REQUEST_CURSOR_MISMATCH") { _ = try await observer.send(request(1), options: TransportOptions()) }
        }
        await runCase("OFF-008", "Unsafe URLs", "safeHTTPS/LinkParser.parse", "reject 4 unsafe URLs and unrelated profile") {
            let values = ["http://example.org/x", "https://user:fixture@example.org/x", "https://example.org:123/x", "https://example.org/x#fragment"]
            let rejected = values.filter { safeHTTPS($0) == nil }.count
            let unrelated = LinkParser().parse("https://example.org/user/offline_fixture") == nil
            let actual = "rejected=\(rejected);unrelated_rejected=\(unrelated)"
            try check(rejected == 4 && unrelated, actual)
            return actual
        }
        await runCase("OFF-009", "JSON integer types", "integer", "status=0;cursor=900;boolean/fraction rejected") {
            let object = try JSONSerialization.jsonObject(with: Data(first.utf8)) as! [String: Any]
            let status = integer(object["status_code"]), cursor = integer(object["max_cursor"])
            let actual = "status=\(String(describing: status));cursor=\(String(describing: cursor));bool=\(String(describing: integer(true)));fraction=\(String(describing: integer(1.5)))"
            try check(status == 0 && cursor == 900 && integer(true) == nil && integer(1.5) == nil, actual)
            return actual
        }
        await runCase("OFF-010", "Pagination flag type", "JSONSerialization/NSNumber", "has_more numeric 1") {
            let object = try JSONSerialization.jsonObject(with: Data(first.utf8)) as! [String: Any]
            let flag = object["has_more"] as? NSNumber
            let actual = "number_present=\(flag != nil);number_string=\(flag?.stringValue ?? "missing");bool=\(String(describing: flag?.boolValue))"
            try check(flag?.stringValue == "1" && flag?.boolValue == true, actual)
            return actual
        }
        await runCase("OFF-011", "Model field mapping", "DouyinExtractor.work", "fixture ID/description/timestamp preserved") {
            let node = try JSONNode(data: Data(first.utf8))
            guard let raw = node.nodes("aweme_list").first else { throw OfflineMismatch(actual: "missing_fixture_item") }
            let work = DouyinExtractor().work(from: raw, collectionTime: "")
            let actual = "id_matches=\(work.id == "1234567890123456789");description_matches=\(work.desc == "fixture");timestamp=\(work.createTimestamp)"
            try check(work.id == "1234567890123456789" && work.desc == "fixture" && work.createTimestamp == 1, actual)
            return actual
        }
        await runCase("OFF-012", "Stop after server exhaustion", "ObservingTransport.sendChecked", "PAGE_LIMIT_OR_EXHAUSTED") {
            let observer = ObservingTransport(base: FixtureTransport([response(last)]))
            _ = try await observer.send(request(0), options: TransportOptions())
            return try await expectStop("PAGE_LIMIT_OR_EXHAUSTED") { _ = try await observer.send(request(800), options: TransportOptions()) }
        }
        await runCase("OFF-013", "Failed-page state", "ObservingTransport.send catch", "one error page HTTP_403;zero fields;no candidate") {
            let observer = ObservingTransport(base: FixtureTransport([response("", status: 403)]))
            _ = try await expectStop("HTTP_403", blocked: true) { _ = try await observer.send(request(0), options: TransportOptions()) }
            let result = await observer.snapshot()
            let actual = "pages=\(result.pages.count);error=\(result.pages.first?.error ?? "missing");fields=\(result.fields.count);candidate=\(result.candidate != nil)"
            try check(result.pages.count == 1 && result.pages[0].error == "HTTP_403" && result.fields.isEmpty && result.candidate == nil, actual)
            return actual
        }
        await runCase("OFF-014", "Media host allowlist", "ObservingTransport.allowMedia", "MEDIA_HOST_OUTSIDE_ALLOWLIST") {
            let observer = ObservingTransport(base: FixtureTransport([]))
            return try await expectStop("MEDIA_HOST_OUTSIDE_ALLOWLIST", blocked: true) { try await observer.allowMedia("https://example.org/fixture.mp4") }
        }
        await runCase("OFF-015", "Reject HTML media bytes", "ObservingTransport.sendChecked", "MEDIA_CONTAINER_NOT_MP4;no media hash") {
            let observer = ObservingTransport(base: FixtureTransport([response("<html>not media</html>")]))
            let address = "https://fixture.douyinvod.com/offline.mp4"
            try await observer.allowMedia(address)
            let result = try await expectStop("MEDIA_CONTAINER_NOT_MP4") {
                _ = try await observer.send(SignedRequest(method: .get, baseURL: address, query: "", headers: [:]), options: TransportOptions())
            }
            let snapshot = await observer.snapshot()
            try check(snapshot.mediaHash == nil, "media_hash_present=\(snapshot.mediaHash != nil)")
            return result
        }
        await runCase("OFF-016", "Exception classification", "RuntimeAcceptance.classify", "missing credentials BLOCKED;storage FAIL") {
            let missing = RuntimeAcceptance.classify(DouStudioError.missingCredentials("fixture"))
            let storage = RuntimeAcceptance.classify(DouStudioError.storage(underlying: "fixture"))
            let actual = "missing=\(missing.code),\(missing.blocked);storage=\(storage.code),\(storage.blocked)"
            try check(missing.blocked && !storage.blocked && missing.code == "UPSTREAM_MISSING_CREDENTIALS" && storage.code == "UPSTREAM_STORAGE_ERROR", actual)
            return actual
        }
        await runCase("OFF-017", "Exact endpoint routing regression", "ObservingTransport.sendChecked", "exact endpoint reaches worklist;4 near-miss endpoints rejected before transport") {
            let observer = ObservingTransport(base: FixtureTransport([response(last)]))
            _ = try await observer.send(request(0), options: TransportOptions())
            let snapshot = await observer.snapshot()
            try check(snapshot.exchanges.count == 1 && snapshot.exchanges[0].kind == "worklist" && snapshot.pages.count == 1,
                      "exchanges=\(snapshot.exchanges.count);kind=\(snapshot.exchanges.first?.kind ?? "missing");pages=\(snapshot.pages.count)")
            let addresses = [
                "https://www.douyin.com/aweme/v1/web/aweme/post",
                "https://www.douyin.com/aweme/v1/web/aweme/post/extra",
                "https://www.douyin.com/aweme/v1/web/aweme/poster/",
                "https://example.org/aweme/v1/web/aweme/post/"
            ]
            for address in addresses {
                let rejected = ObservingTransport(base: FixtureTransport([]))
                _ = try await expectStop("UNEXPECTED_REQUEST_OR_DOWNLOAD_LIMIT", blocked: true) {
                    _ = try await rejected.send(SignedRequest(method: .get, baseURL: address, query: "max_cursor=0", headers: [:]), options: TransportOptions())
                }
                let state = await rejected.snapshot()
                try check(state.exchanges.isEmpty && state.pages.isEmpty, "unexpected_fixture_consumption_or_page")
            }
            return "exact_endpoint_worklist=true;near_miss_rejected=4;near_miss_transport_calls=0"
        }
        await runCase("OFF-018", "HTTP rejection exact category", "ObservingTransport.sendChecked", "HTTP_403;blocked=true;worklist exchange recorded") {
            let observer = ObservingTransport(base: FixtureTransport([response("", status: 403)]))
            let actual = try await expectStop("HTTP_403", blocked: true) {
                _ = try await observer.send(request(0), options: TransportOptions())
            }
            let state = await observer.snapshot()
            try check(state.exchanges.count == 1 && state.exchanges[0].kind == "worklist" && state.exchanges[0].status == 403,
                      "worklist_403_exchange_missing")
            return actual + ";worklist_exchange=true"
        }
        await runCase("OFF-019", "HTML rejection exact category", "ObservingTransport.observePage", "NON_JSON_POSSIBLE_ACCESS_CHALLENGE;blocked=true") {
            let observer = ObservingTransport(base: FixtureTransport([response("<html>challenge</html>")]))
            return try await expectStop("NON_JSON_POSSIBLE_ACCESS_CHALLENGE", blocked: true) {
                _ = try await observer.send(request(0), options: TransportOptions())
            }
        }
        // Diagnostic scalars explain Foundation URL behavior without logging a URL.
        if let url = request(0).url {
            print("URL_SHAPE legacy_path_matches=\(url.path == "/aweme/v1/web/aweme/post/");components_path_matches=\(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == "/aweme/v1/web/aweme/post/");host_matches=\(url.host == "www.douyin.com")")
        }
        let passed = results.allSatisfy { $0.status == "PASS" }
        struct Summary: Encodable {
            let mode = "OFFLINE_FIXTURES_ONLY"
            let transport = "FixtureTransport (memory only)"
            let onlineEntryCalled = false
            let mediaDownloaded = false
            let status: String
            let cases: [OfflineCaseResult]
        }
        let env = ProcessInfo.processInfo.environment
        if let path = env["OFFLINE_RESULTS_PATH"] ?? env["EVIDENCE_DIR"].map({ $0 + "/selftest-results.json" }) {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Summary(status: passed ? "PASS" : "FAIL", cases: results))
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("OFFLINE SUMMARY total=\(results.count) passed=\(results.filter { $0.status == "PASS" }.count) failed=\(results.filter { $0.status == "FAIL" }.count)")
        return passed
    }
}
