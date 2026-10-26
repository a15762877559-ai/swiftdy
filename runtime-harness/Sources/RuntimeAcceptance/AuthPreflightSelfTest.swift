import Foundation
import DouStudioKit

private actor AuthFixtureTransport: HTTPTransport {
    let response: HTTPResponse
    var calls = 0
    init(_ response: HTTPResponse) { self.response = response }
    func send(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        guard !options.followRedirects, options.proxy == nil, options.extraHeaders.isEmpty else { throw AuthPreflightError.scope }
        calls += 1
        return response // In-memory fixture; no URLSession or media writer.
    }
}

@MainActor enum AuthPreflightSelfTest {
    static let fixtureCookie = "offline_fixture=synthetic" // Not an account credential.
    static func input() throws -> AuthPreflightInput {
        try .validate(consent: true, cookie: fixtureCookie, profile: "https://www.douyin.com/user/offline_fixture")
    }
    static func request(base: String = "https://www.douyin.com/aweme/v1/web/aweme/post/",
                        query: String = "max_cursor=0&count=18&sec_user_id=offline_fixture",
                        headers: [String: String] = ["Cookie": fixtureCookie]) -> SignedRequest {
        SignedRequest(method: .get, baseURL: base, query: query, headers: headers)
    }
    static func expect(_ category: AuthPreflightError, _ body: @MainActor () async throws -> Void) async throws {
        do { try await body() }
        catch let actual as AuthPreflightError where actual == category { return }
        throw AuthPreflightError.unknown
    }
    static func require(_ condition: Bool) throws { if !condition { throw AuthPreflightError.unknown } }
    static func run() async -> [OfflineCaseResult] {
        var results: [OfflineCaseResult] = []
        func test(_ id: String, _ name: String, _ expected: String, _ body: @MainActor () async throws -> Void) async {
            print("BEGIN \(id) | \(name) | function=AuthPreflight")
            let result: OfflineCaseResult
            do {
                try await body()
                result = OfflineCaseResult(id: id, name: name, function: "AuthPreflight", status: "PASS", errorCategory: "NONE", expected: expected, actual: "expected_condition_verified")
            } catch {
                result = OfflineCaseResult(id: id, name: name, function: "AuthPreflight", status: "FAIL",
                    errorCategory: (error as? AuthPreflightError)?.rawValue ?? "REDACTED", expected: expected, actual: "expected_condition_not_met")
            }
            results.append(result)
            if let data = try? JSONEncoder().encode(result), let line = String(data: data, encoding: .utf8) { print(line) }
        }
        await test("AUTH-001", "Explicit consent", "missing consent rejected before transport") {
            try await expect(.consent) { _ = try AuthPreflightInput.validate(consent: false, cookie: fixtureCookie, profile: "https://www.douyin.com/user/offline_fixture") }
        }
        await test("AUTH-002", "Missing secret", "empty credential rejected before transport") {
            try await expect(.missing) { _ = try AuthPreflightInput.validate(consent: true, cookie: "", profile: "https://www.douyin.com/user/offline_fixture") }
        }
        await test("AUTH-003", "Header injection", "control characters rejected") {
            try await expect(.credential) { _ = try AuthPreflightInput.validate(consent: true, cookie: "fixture=x\r\nInjected:y", profile: "https://www.douyin.com/user/offline_fixture") }
        }
        await test("AUTH-004", "Profile scope", "foreign profile rejected") {
            try await expect(.profile) { _ = try AuthPreflightInput.validate(consent: true, cookie: fixtureCookie, profile: "https://example.org/user/offline_fixture") }
        }
        await test("AUTH-005", "One request and field counts", "one successful fixture then hard stop") {
            let base = AuthFixtureTransport(SelfTest.response(SelfTest.first))
            let transport = AuthPreflightTransport(input: try input(), base: base)
            _ = try await transport.send(request(), options: TransportOptions())
            try await expect(.limit) { _ = try await transport.send(request(), options: TransportOptions()) }
            let s = await transport.snapshot(), calls = await base.calls
            try require(calls == 1 && s.item_count == 1 && s.valid_worklist && s.fields["id_valid"] == 1 && s.fields["description_present"] == 1 && s.fields["timestamp_valid"] == 1)
        }
        await test("AUTH-006", "No credential forwarding to foreign host", "foreign request rejected with zero fixture calls") {
            let base = AuthFixtureTransport(SelfTest.response(SelfTest.first))
            let transport = AuthPreflightTransport(input: try input(), base: base)
            try await expect(.scope) { _ = try await transport.send(request(base: "https://example.org/aweme/v1/web/aweme/post/"), options: TransportOptions()) }
            let calls = await base.calls; try require(calls == 0)
        }
        await test("AUTH-007", "No second-page cursor", "nonzero cursor rejected before send") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response(SelfTest.first)))
            try await expect(.scope) { _ = try await transport.send(request(query: "max_cursor=1&count=18&sec_user_id=offline_fixture"), options: TransportOptions()) }
        }
        await test("AUTH-008", "Credential header boundary", "missing, changed or additional authorization headers rejected") {
            for headers in [[:], ["Cookie":"offline_fixture=other"], ["Cookie":fixtureCookie,"Authorization":"synthetic"]] {
                let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response(SelfTest.first)))
                try await expect(.scope) { _ = try await transport.send(request(headers: headers), options: TransportOptions()) }
            }
        }
        await test("AUTH-009", "403 handling", "ACCESS_RESTRICTED and no second send") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response("", status: 403)))
            try await expect(.access) { _ = try await transport.send(request(), options: TransportOptions()) }
            try await expect(.limit) { _ = try await transport.send(request(), options: TransportOptions()) }
            let s = await transport.snapshot(); try require(s.http_status == 403 && s.request_count == 1)
        }
        await test("AUTH-010", "Rate limit", "429 is RATE_LIMITED") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response("", status: 429)))
            try await expect(.rate) { _ = try await transport.send(request(), options: TransportOptions()) }
        }
        await test("AUTH-011", "Challenge body", "200 HTML does not pass") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response("<html>challenge</html>")))
            try await expect(.challenge) { _ = try await transport.send(request(), options: TransportOptions()) }
        }
        await test("AUTH-012", "Empty list", "valid empty list is inconclusive") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response(SelfTest.last)))
            try await expect(.empty) { _ = try await transport.send(request(), options: TransportOptions()) }
            let s = await transport.snapshot(); try require(s.valid_worklist && s.item_count == 0)
        }
        await test("AUTH-013", "Response shape", "200 unrelated JSON rejected") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response(#"{"status_code":0,"other":[]}"#)))
            try await expect(.response) { _ = try await transport.send(request(), options: TransportOptions()) }
        }
        await test("AUTH-014", "Redirect rejection", "302 stopped without follow") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response("", status: 302)))
            try await expect(.access) { _ = try await transport.send(request(), options: TransportOptions()) }
        }
        await test("AUTH-015", "Original client pipeline with memory fixture", "has_more=1 still only one original client request") {
            let base = AuthFixtureTransport(SelfTest.response(SelfTest.first))
            let transport = AuthPreflightTransport(input: try input(), base: base)
            let config = KernelConfiguration(storageTargets: [], pageSize: 18, maxPages: 1, maxConcurrency: 1, maxRetry: 0, timeout: 30, preferOriginalQuality: false)
            let client = try await DouyinClient(configuration: config, cookie: fixtureCookie, transport: transport, logger: .disabled)
            let endpoints = await client.endpoints
            _ = try await endpoints.accountTimeline(secUid: "offline_fixture", tab: .post, page: PageRequest(count: 18, maxPages: 1, cursor: 0))
            let calls = await base.calls; try require(calls == 1)
        }
        await test("AUTH-016", "Anonymous guard unchanged", "anonymous observer rejects cookie before memory send") {
            let observer = ObservingTransport(base: AuthFixtureTransport(SelfTest.response(SelfTest.first)))
            _ = try await SelfTest.expectStop("REQUEST_SCOPE_REJECTED", blocked: true) { _ = try await observer.send(request(), options: TransportOptions()) }
        }
        await test("AUTH-017", "No media endpoint", "media URL rejected before send") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response("fixture")))
            try await expect(.scope) { _ = try await transport.send(request(base: "https://www.douyin.com/video/fixture"), options: TransportOptions()) }
        }
        await test("AUTH-018", "No proxy or extra headers", "proxy or extra header options rejected") {
            for options in [TransportOptions(extraHeaders: ["Cookie":fixtureCookie]), TransportOptions(proxy: URL(string:"http://127.0.0.1:1"))] {
                let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response(SelfTest.first)))
                try await expect(.scope) { _ = try await transport.send(request(), options: options) }
            }
        }
        await test("AUTH-019", "Work item identity", "JSON list with invalid item identity is not accepted") {
            let transport = AuthPreflightTransport(input: try input(), base: AuthFixtureTransport(SelfTest.response(#"{"status_code":0,"aweme_list":[{}],"max_cursor":0,"has_more":0}"#)))
            try await expect(.response) { _ = try await transport.send(request(), options: TransportOptions()) }
            let s = await transport.snapshot(); try require(!s.valid_worklist && s.item_count == 1 && s.fields["id_valid"] == 0)
        }
        return results
    }
}
