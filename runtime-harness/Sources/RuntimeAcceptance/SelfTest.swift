import Foundation
import DouStudioKit

/// Synthetic in-memory fixtures. These are never accepted as real runtime evidence.
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

enum SelfTest {
    static func require(_ condition: Bool) throws {
        if !condition { throw AcceptanceStop(code: "SELF_TEST_ASSERTION", blocked: false) }
    }

    static func request(_ cursor: Int) -> SignedRequest {
        SignedRequest(method: .get, baseURL: "https://www.douyin.com/aweme/v1/web/aweme/post/",
                      query: "max_cursor=\(cursor)", headers: [:])
    }

    static func response(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8), finalURL: nil)
    }

    static func run() async throws {
        let input = "https://www.douyin.com/user/offline_fixture"
        guard let link = LinkParser().parse(input), case .user(let id, _) = link.target else {
            throw AcceptanceStop(code: "PARSER_FIXTURE", blocked: false)
        }
        try require(id == "offline_fixture")
        let first = #"{"status_code":0,"aweme_list":[{"aweme_id":"1234567890123456789","desc":"fixture","create_time":1}],"max_cursor":900,"has_more":1}"#
        let last = #"{"status_code":0,"aweme_list":[],"max_cursor":800,"has_more":0}"#
        let observer = ObservingTransport(base: FixtureTransport([response(first), response(last)]))
        _ = try await observer.send(request(0), options: TransportOptions())
        _ = try await observer.send(request(900), options: TransportOptions())
        let result = await observer.snapshot()
        try require(result.pages.count == 2 && result.pages[1].requestCursor == "900")
        try require(result.pages[1].hasMore == false && result.fields.count == 1)
        // A repeated server cursor must be rejected before another request.
        let stalled = ObservingTransport(base: FixtureTransport([response(first), response(first)]))
        _ = try await stalled.send(request(0), options: TransportOptions())
        do {
            _ = try await stalled.send(request(900), options: TransportOptions())
            throw AcceptanceStop(code: "EXPECTED_CURSOR_FAILURE", blocked: false)
        } catch let error as AcceptanceStop { try require(error.code == "CURSOR_STALLED_OR_CYCLIC") }
        for fixture in [response("", status: 403), response("<html>challenge</html>")] {
            let blocked = ObservingTransport(base: FixtureTransport([fixture]))
            do {
                _ = try await blocked.send(request(0), options: TransportOptions())
                throw AcceptanceStop(code: "EXPECTED_ACCESS_STOP", blocked: false)
            } catch let error as AcceptanceStop { try require(error.blocked) }
        }
        let mismatch = ObservingTransport(base: FixtureTransport([]))
        do {
            _ = try await mismatch.send(request(1), options: TransportOptions())
            throw AcceptanceStop(code: "EXPECTED_REQUEST_CURSOR_FAILURE", blocked: false)
        } catch let error as AcceptanceStop { try require(error.code == "REQUEST_CURSOR_MISMATCH") }
    }
}
