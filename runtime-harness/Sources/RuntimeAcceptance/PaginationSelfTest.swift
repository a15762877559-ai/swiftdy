import Foundation
import DouStudioKit

private actor PaginationFixture: HTTPTransport {
    var responses: [HTTPResponse]
    var calls = 0
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        guard !options.followRedirects, options.proxy == nil, options.extraHeaders.isEmpty, options.timeout == 30,
              !responses.isEmpty else { throw PaginationFailure.harness }
        calls += 1
        return responses.removeFirst() // No network, files, or media operations.
    }
}

private struct PaginationTestMismatch: Error { let summary: String }

@MainActor enum PaginationSelfTest {
    static func page(_ ids: [String], _ cursor: Int64?, _ more: Bool) throws -> HTTPResponse {
        var object: [String: Any] = ["status_code":0, "aweme_list":ids.map { ["aweme_id":$0] }, "has_more":more ? 1 : 0]
        if let cursor { object["max_cursor"] = cursor }
        return HTTPResponse(statusCode:200, headers:[:], body:try JSONSerialization.data(withJSONObject:object), finalURL:nil)
    }
    static func require(_ condition: Bool, _ summary: String) throws {
        if !condition { throw PaginationTestMismatch(summary: summary) }
    }
    static func runPipeline(_ responses: [HTTPResponse]) async throws -> (PaginationResult, PaginationTransport, Int) {
        let input = try AuthPreflightSelfTest.input()
        let base = PaginationFixture(responses)
        let transport = PaginationTransport(input:input, base:base)
        var failure: PaginationFailure?
        var completed = false
        do { try await AuthenticatedPagination.collect(input: input, transport: transport); completed = true }
        catch { failure = await transport.failure() ?? (error as? PaginationFailure) ?? .harness }
        var result = PaginationResult(credential_present:true)
        result.assess(pages:await transport.snapshot(), failure:failure, completed:completed)
        return (result, transport, await base.calls)
    }
    static func request(_ cursor: Int64) -> SignedRequest {
        AuthPreflightSelfTest.request(query:"max_cursor=\(cursor)&count=18&sec_user_id=offline_fixture")
    }
    static func expect(_ failure: PaginationFailure, _ operation: @MainActor () async throws -> Void) async throws {
        do { try await operation() }
        catch let actual as PaginationFailure where actual == failure { return }
        throw PaginationTestMismatch(summary:"expected_fixed_error_not_observed")
    }
    static func run() async throws -> Bool {
        var results: [OfflineCaseResult] = []
        func test(_ id: String, _ name: String, _ expected: String, _ body: @MainActor () async throws -> String) async {
            print("BEGIN \(id) | \(name) | function=AuthenticatedPagination.collect/PaginationTransport.send")
            let result: OfflineCaseResult
            do {
                result = OfflineCaseResult(id:id, name:name, function:"AuthenticatedPagination.collect/PaginationTransport.send", status:"PASS", errorCategory:"NONE", expected:expected, actual:try await body())
            } catch {
                result = OfflineCaseResult(id:id, name:name, function:"AuthenticatedPagination.collect/PaginationTransport.send", status:"FAIL", errorCategory:(error as? PaginationFailure)?.rawValue ?? "ASSERTION_MISMATCH", expected:expected,
                    actual:(error as? PaginationTestMismatch)?.summary ?? "fixed_error_or_condition_mismatch")
            }
            results.append(result)
            if let data = try? JSONEncoder().encode(result), let line = String(data:data, encoding:.utf8) { print(line) }
        }
        await test("PAG-001", "Two-page original collector", "calls=2;chain=true;correctness=PASS;SERVER_EXHAUSTED") {
            let (r, _, calls) = try await runPipeline([page(["1"],901,true),page(["2"],800,false)])
            try require(calls == 2 && r.statuses["PAGINATION_CORRECTNESS"] == "PASS" && r.pages[1].uses_previous_response_cursor == true && r.stop_reason == "SERVER_EXHAUSTED", "two_page_pipeline_or_cursor_chain_mismatch")
            return "calls=2;chain=true;correctness=PASS;SERVER_EXHAUSTED"
        }
        await test("PAG-002", "Three-page original collector and hard cap", "calls=3;fourth rejected;correctness=PASS") {
            let (r, transport, calls) = try await runPipeline([page(["1"],901,true),page(["2"],703,true),page(["3"],405,true),page(["4"],200,false)])
            try require(calls == 3 && r.pages.count == 3 && r.statuses["PAGINATION_CORRECTNESS"] == "PASS" && r.stop_reason == "PAGE_LIMIT_REACHED", "three_page_or_cap_mismatch")
            try await expect(.limit) { _ = try await transport.send(request(405), options:TransportOptions()) }
            return "calls=3;fourth rejected;correctness=PASS"
        }
        await test("PAG-003", "First-page exhaustion", "calls=1;MULTI_PAGE_FETCH=NOT_VERIFIED;SERVER_EXHAUSTED") {
            let (r, _, calls) = try await runPipeline([page(["1"],nil,false),page(["2"],1,false)])
            try require(calls == 1 && r.statuses["FIRST_PAGE_FETCH"] == "PASS" && r.statuses["MULTI_PAGE_FETCH"] == "NOT_VERIFIED" && r.stop_reason == "SERVER_EXHAUSTED", "first_page_exhaustion_falsely_proves_pagination")
            return "calls=1;MULTI_PAGE_FETCH=NOT_VERIFIED;SERVER_EXHAUSTED"
        }
        await test("PAG-004", "Empty first page", "calls=1;first page BLOCKED;pagination NOT_VERIFIED") {
            let (r, _, calls) = try await runPipeline([page([],nil,false)])
            try require(calls == 1 && r.statuses["FIRST_PAGE_FETCH"] == "BLOCKED" && r.statuses["PAGINATION_CORRECTNESS"] == "NOT_VERIFIED", "empty_page_falsely_passed")
            return "calls=1;first page BLOCKED;pagination NOT_VERIFIED"
        }
        let failures: [(String,String,[HTTPResponse],PaginationFailure,Int)] = [
            ("PAG-005","Missing cursor",[try page(["1"],nil,true)],.cursor,1),
            ("PAG-006","Invalid cursor zero",[try page(["1"],0,true)],.cursor,1),
            ("PAG-007","Stalled cursor",[try page(["1"],901,true),try page(["2"],901,true)],.stall,2),
            ("PAG-008","Cursor cycle",[try page(["1"],901,true),try page(["2"],703,true),try page(["3"],901,true)],.cycle,3),
            ("PAG-009","Duplicate across pages",[try page(["1","2"],901,true),try page(["2","3"],800,false)],.duplicate,2),
            ("PAG-010","Duplicate within page",[try page(["1","1","1"],800,false)],.duplicate,1),
            ("PAG-011","403 stops",[SelfTest.response("",status:403)],.access,1),
            ("PAG-012","429 on second page stops",[try page(["1"],901,true),SelfTest.response("",status:429)],.rate,2),
            ("PAG-013","HTML challenge stops",[SelfTest.response("<html>fixture challenge</html>")],.challenge,1),
            ("PAG-014","Response schema changed",[SelfTest.response(#"{"status_code":0,"other":[]}"#)],.response,1),
            ("PAG-015","Missing has_more",[SelfTest.response(#"{"status_code":0,"aweme_list":[],"max_cursor":3}"#)],.response,1),
            ("PAG-016","Empty with more",[try page([],901,true)],.empty,1),
            ("PAG-017","Redirect stops",[SelfTest.response("",status:302)],.access,1),
            ("PAG-018","Invalid work identity",[try page(["not_numeric"],800,false)],.response,1),
            ("PAG-019","Platform error",[SelfTest.response(#"{"status_code":8,"aweme_list":[]}"#)],.access,1)
        ]
        for (id,name,responses,failure,expectedCalls) in failures {
            await test(id,name,"error=\(failure.rawValue);calls=\(expectedCalls);stopped;no media") {
                let (r, transport, calls) = try await runPipeline(responses + [page(["999"],1,false)])
                try require(calls == expectedCalls && r.failure_reason == failure.rawValue && !r.pipeline_completed && r.statuses["VIDEO_DOWNLOAD"] == "NOT_RUN", "error_or_request_count_mismatch")
                try await expect(calls == 3 ? .limit : .stopped) { _ = try await transport.send(request(0),options:TransportOptions()) }
                if id == "PAG-009" { try require(r.pages.last?.duplicate_ids == 1 && r.pages.last?.cumulative_items == 4 && r.pages.last?.cumulative_unique_items == 3,"cross_page_duplicate_count_wrong") }
                if id == "PAG-010" { try require(r.pages[0].duplicate_ids == 2 && r.pages[0].cumulative_unique_items == 1,"within_page_duplicate_count_wrong") }
                return "error=\(failure.rawValue);calls=\(calls);stopped;no media"
            }
        }
        await test("PAG-020","Wrong next request cursor","chain mismatch rejected before second send") {
            let base = PaginationFixture([try page(["1"],901,true),try page(["2"],800,false)])
            let t = PaginationTransport(input:try AuthPreflightSelfTest.input(),base:base)
            _ = try await t.send(request(0),options:TransportOptions())
            try await expect(.chain) { _ = try await t.send(request(900),options:TransportOptions()) }
            let calls = await base.calls; try require(calls == 1,"wrong_cursor_reached_base")
            return "chain mismatch rejected before second send"
        }
        await test("PAG-021","Media endpoint forbidden","scope rejected;calls=0") {
            let base = PaginationFixture([])
            let t = PaginationTransport(input:try AuthPreflightSelfTest.input(),base:base)
            try await expect(.scope) { _ = try await t.send(AuthPreflightSelfTest.request(base:"https://www.douyin.com/video/fixture"),options:TransportOptions()) }
            let calls = await base.calls; try require(calls == 0,"media_reached_base")
            return "scope rejected;calls=0"
        }
        await test("PAG-022","Foreign host and credential boundary","foreign host, missing cookie and proxy rejected;calls=0") {
            for (req, options) in [(AuthPreflightSelfTest.request(base:"https://example.org/aweme/v1/web/aweme/post/"),TransportOptions()),(AuthPreflightSelfTest.request(headers:[:]),TransportOptions()),(request(0),TransportOptions(proxy:URL(string:"http://127.0.0.1:1")))] {
                let base = PaginationFixture([])
                let t = PaginationTransport(input:try AuthPreflightSelfTest.input(),base:base)
                try await expect(.scope) { _ = try await t.send(req,options:options) }
                let calls = await base.calls; try require(calls == 0,"credential_scope_reached_base")
            }
            return "foreign host, missing cookie and proxy rejected;calls=0"
        }
        await test("PAG-023","Evidence excludes identifiers and cursor values","structured JSON has no cookie, IDs, raw cursors or URLs") {
            let (r, _, _) = try await runPipeline([page(["12345678901234567"],901,true),page(["22345678901234567"],800,false)])
            let text = String(decoding:try JSONEncoder().encode(r),as:UTF8.self)
            try require(!text.contains(AuthPreflightSelfTest.fixtureCookie) && !text.contains("12345678901234567") && !text.contains("22345678901234567") && !text.contains("901") && !text.contains("https://"),"evidence_contains_prohibited_fixture_value")
            return "structured JSON has no cookie, IDs, raw cursors or URLs"
        }
        await test("PAG-024","Network exception stops without retry","NETWORK_ERROR;calls recorded=1;no subsequent send") {
            let (r,t,_) = try await runPipeline([])
            try require(r.failure_reason == "NETWORK_ERROR" && r.request_count == 1,"network_exception_not_recorded")
            try await expect(.stopped) { _ = try await t.send(request(0),options:TransportOptions()) }
            return "NETWORK_ERROR;calls recorded=1;no subsequent send"
        }
        let passed = results.allSatisfy { $0.status == "PASS" }
        struct Summary: Encodable {
            let mode = "OFFLINE_FIXTURES_ONLY"
            let onlineEntryCalled = false
            let mediaDownloaded = false
            let status: String
            let cases: [OfflineCaseResult]
        }
        guard let folder = ProcessInfo.processInfo.environment["PAGINATION_EVIDENCE_DIR"] else { throw PaginationFailure.scope }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(Summary(status:passed ? "PASS" : "FAIL",cases:results)).write(to:URL(fileURLWithPath:folder).appendingPathComponent("pagination-selftest-results.json"),options:.atomic)
        print("PAGINATION OFFLINE total=\(results.count) passed=\(results.filter { $0.status == "PASS" }.count)")
        return passed
    }
}
