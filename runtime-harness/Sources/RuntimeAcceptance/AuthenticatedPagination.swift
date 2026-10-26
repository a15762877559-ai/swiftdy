import Foundation
import CoreFoundation
import DouStudioKit

enum PaginationFailure: String, Error, Sendable {
    case scope = "REQUEST_SCOPE_REJECTED"
    case limit = "REQUEST_LIMIT"
    case stopped = "ALREADY_STOPPED"
    case chain = "CURSOR_CHAIN_MISMATCH"
    case cursor = "CURSOR_MISSING_OR_INVALID"
    case stall = "CURSOR_STALLED"
    case cycle = "CURSOR_CYCLE"
    case duplicate = "DUPLICATE_WORK_IDS"
    case empty = "EMPTY_PAGE_WITH_MORE"
    case network = "NETWORK_ERROR"
    case access = "ACCESS_RESTRICTED"
    case rate = "RATE_LIMITED"
    case challenge = "CHALLENGE_REQUIRED"
    case response = "API_RESPONSE_CHANGED"
    case harness = "HARNESS_ERROR"

    var category: String {
        switch self {
        case .chain, .cursor, .stall, .cycle, .duplicate, .empty: return "PAGINATION_ERROR"
        case .scope, .limit, .stopped, .harness: return "HARNESS_ERROR"
        default: return rawValue
        }
    }
    var blocked: Bool { self == .access || self == .rate || self == .challenge }
}

struct PaginationPage: Codable, Sendable {
    var page: Int
    var request_started = false
    var uses_previous_response_cursor: Bool? // nil for page 1; no raw cursors/IDs.
    var http_status: Int?
    var has_more: Bool?
    var returned_cursor_valid: Bool?
    var item_count: Int?
    var cumulative_items = 0
    var cumulative_unique_items = 0
    var duplicate_ids = 0 // Repeated occurrences, including within this page.
    var cursor_stalled = false
    var cursor_cycle = false
    var valid_page = false
    var failure_category: String?
    var failure_reason: String?
}

/// Checks the actual signed request and original response, never generates a cursor.
actor PaginationTransport: HTTPTransport {
    private let input: AuthPreflightInput
    private let base: any HTTPTransport
    private var expectedCursor: Int64 = 0
    private var usedCursors: Set<Int64> = []
    private var seenIDs: Set<String> = [] // Memory only, never serialized.
    private var pages: [PaginationPage] = []
    private var total = 0
    private var inFlight = false
    private var stopped = false
    private var terminalFailure: PaginationFailure?

    init(input: AuthPreflightInput, base: any HTTPTransport) { self.input = input; self.base = base }
    func snapshot() -> [PaginationPage] { pages }
    func failure() -> PaginationFailure? { terminalFailure }

    private func reject(_ error: PaginationFailure) -> PaginationFailure {
        stopped = true
        if terminalFailure == nil { terminalFailure = error }
        return error
    }

    func send(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        guard pages.count < 3 else { throw reject(.limit) }
        guard !stopped && !inFlight else { throw reject(.stopped) }
        guard request.method == .get, request.body == nil, options.extraHeaders.isEmpty,
              options.proxy == nil, let url = request.url, safeHTTPS(url.absoluteString) != nil,
              url.host == "www.douyin.com",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/aweme/v1/web/aweme/post/" else { throw reject(.scope) }
        let query = components.queryItems ?? []
        func only(_ key: String) -> String? {
            let values = query.filter { $0.name == key }
            return values.count == 1 ? values[0].value : nil
        }
        let cookies = request.headers.filter { $0.key.lowercased() == "cookie" }
        guard only("count") == "18", only("sec_user_id") == input.userID,
              cookies.count == 1, cookies.first?.value == input.cookie,
              !request.headers.keys.contains(where: { ["authorization", "proxy-authorization"].contains($0.lowercased()) }) else { throw reject(.scope) }
        guard only("max_cursor") == String(expectedCursor) else { throw reject(.chain) }
        let cursor = expectedCursor
        let index = pages.count
        pages.append(PaginationPage(page: index + 1, request_started: true,
                                    uses_previous_response_cursor: index == 0 ? nil : true,
                                    cumulative_items: total, cumulative_unique_items: seenIDs.count))
        usedCursors.insert(cursor)
        inFlight = true // Reserve before awaiting: concurrent and repeated calls fail closed.
        defer { inFlight = false }
        do {
            var bounded = options; bounded.followRedirects = false; bounded.timeout = 30
            let response: HTTPResponse
            do { response = try await base.send(request, options: bounded) }
            catch { throw PaginationFailure.network }
            if let terminalFailure { throw terminalFailure }
            pages[index].http_status = response.statusCode
            switch response.statusCode {
            case 200: break
            case 429: throw PaginationFailure.rate
            case 401, 403, 404, 300..<400: throw PaginationFailure.access
            default: throw PaginationFailure.response
            }
            let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
            guard !type.contains("html"), let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { throw PaginationFailure.challenge }
            guard let status = integer(object["status_code"]) else { throw PaginationFailure.response }
            guard status == 0 else { throw PaginationFailure.access }
            guard let items = object["aweme_list"] as? [[String: Any]], items.count <= 50 else { throw PaginationFailure.response }
            // Strict 0/1 or JSON boolean, matching the upstream supported flag shape.
            let flag: Bool
            if let number = integer(object["has_more"]), number == 0 || number == 1 { flag = number == 1 }
            else if let number = object["has_more"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { flag = number.boolValue }
            else { throw PaginationFailure.response }
            pages[index].has_more = flag
            let next = integer(object["max_cursor"])
            pages[index].returned_cursor_valid = next.map { flag ? $0 > 0 : $0 >= 0 } ?? false
            pages[index].item_count = items.count
            var ids: [String] = []
            for item in items {
                guard let id = item["aweme_id"] as? String, !id.isEmpty, id.count <= 30,
                      id.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw PaginationFailure.response }
                ids.append(id)
            }
            for id in ids { if !seenIDs.insert(id).inserted { pages[index].duplicate_ids += 1 } }
            total += ids.count
            pages[index].cumulative_items = total
            pages[index].cumulative_unique_items = seenIDs.count
            if flag {
                guard let next, next > 0 else { throw PaginationFailure.cursor }
                pages[index].cursor_stalled = next == cursor
                pages[index].cursor_cycle = usedCursors.contains(next)
                if next == cursor { throw PaginationFailure.stall }
                if usedCursors.contains(next) { throw PaginationFailure.cycle }
                guard !items.isEmpty else { throw PaginationFailure.empty }
                expectedCursor = next // Observation only: upstream collector chooses the next request.
            } else { stopped = true }
            guard pages[index].duplicate_ids == 0 else { throw PaginationFailure.duplicate }
            pages[index].valid_page = true
            return response // Original bytes go back into the original collector.
        } catch {
            let safe = error as? PaginationFailure ?? .harness
            pages[index].failure_category = safe.category
            pages[index].failure_reason = safe.rawValue
            throw reject(safe)
        }
    }
}

struct PaginationResult: Codable, Sendable {
    var credential_present: Bool
    var statuses = ["AUTHENTICATED_PROFILE_ACCESS":"NOT_RUN", "FIRST_PAGE_FETCH":"NOT_RUN",
                    "MULTI_PAGE_FETCH":"NOT_RUN", "PAGINATION_CURSOR_CHAIN":"NOT_VERIFIED",
                    "PAGINATION_CORRECTNESS":"NOT_VERIFIED", "VIDEO_DOWNLOAD":"NOT_RUN",
                    "MEDIA_INTEGRITY":"NOT_RUN", "NO_WATERMARK":"NOT_TESTED", "RUST_IMPLEMENTATION":"NOT_STARTED",
                    "UPSTREAM_SOURCE_CHANGED":"NO", "ROOTNETSCOPE_CHANGED":"NO", "VIDEOFLOW_CHANGED":"NO"]
    var pages: [PaginationPage] = []
    var request_count = 0
    var failure_category: String?
    var failure_reason: String?
    var stop_reason: String?
    var pipeline_completed = false

    mutating func assess(pages: [PaginationPage], failure: PaginationFailure?, completed: Bool) {
        self.pages = pages; request_count = pages.count; pipeline_completed = completed
        let good = pages.filter { $0.valid_page && ($0.item_count ?? 0) > 0 }
        if let first = pages.first {
            let firstOK = first.valid_page && (first.item_count ?? 0) > 0
            statuses["FIRST_PAGE_FETCH"] = firstOK ? "PASS" : (failure?.blocked == true ? "BLOCKED" : (first.valid_page ? "BLOCKED" : "FAIL"))
            statuses["AUTHENTICATED_PROFILE_ACCESS"] = statuses["FIRST_PAGE_FETCH"]
        }
        if let failure {
            failure_category = failure.category; failure_reason = failure.rawValue
            statuses["MULTI_PAGE_FETCH"] = failure.blocked ? "BLOCKED" : "FAIL"
            statuses["PAGINATION_CORRECTNESS"] = failure.category == "PAGINATION_ERROR" ? "FAIL" : "NOT_VERIFIED"
            if failure == .chain { statuses["PAGINATION_CURSOR_CHAIN"] = "FAIL" }
            stop_reason = "ERROR"
        } else if completed {
            stop_reason = pages.last?.has_more == false ? "SERVER_EXHAUSTED" : "PAGE_LIMIT_REACHED"
            if good.count >= 2 && pages.allSatisfy({ $0.valid_page }) && pages.dropFirst().allSatisfy({ $0.uses_previous_response_cursor == true }) {
                statuses["MULTI_PAGE_FETCH"] = "PASS"
                statuses["PAGINATION_CURSOR_CHAIN"] = "PASS"
                statuses["PAGINATION_CORRECTNESS"] = "PASS"
            } else {
                // Explicit special case: first-page exhaustion cannot prove multi-page ability.
                statuses["MULTI_PAGE_FETCH"] = "NOT_VERIFIED"
            }
        }
    }
}

enum AuthenticatedPagination {
    @MainActor static func collect(input: AuthPreflightInput, transport: PaginationTransport) async throws {
        let config = KernelConfiguration(storageTargets: [], pageSize: 18, maxPages: 3, maxConcurrency: 1,
                                         maxRetry: 0, timeout: 30, preferOriginalQuality: false)
        let client = try await DouyinClient(configuration: config, cookie: input.cookie, transport: transport, logger: .disabled)
        let endpoints = await client.endpoints
        // Calls upstream PaginatedCollector.collect, with no substitute pagination loop.
        let timeline = try await endpoints.accountTimeline(secUid: input.userID, tab: .post,
                                                            page: PageRequest(count: 18, maxPages: 3, cursor: 0))
        let pages = await transport.snapshot()
        guard !pages.isEmpty, pages.allSatisfy({ $0.valid_page }),
              timeline.works.count == pages.reduce(0, { $0 + ($1.item_count ?? 0) }),
              pages.last?.has_more == false || pages.count == 3 else { throw PaginationFailure.harness }
    }

    @MainActor static func run(environment: [String: String]) async throws -> Bool {
        let cookie = environment["DOUYIN_COOKIE"] ?? ""
        var result = PaginationResult(credential_present: !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        var observer: PaginationTransport?
        do {
            let input = try AuthPreflightInput.validate(consent: environment["AUTH_CONSENT"] == "true", cookie: cookie,
                                                       profile: environment["AUTH_PROFILE"] ?? "")
            let transport = PaginationTransport(input: input, base: URLSessionTransport())
            observer = transport
            try await collect(input: input, transport: transport)
            result.assess(pages: await transport.snapshot(), failure: await transport.failure(), completed: true)
        } catch {
            if let observer {
                let failure = await observer.failure() ?? (error as? PaginationFailure) ?? .harness
                result.assess(pages: await observer.snapshot(), failure: failure, completed: false)
            } else {
                result.failure_category = "INPUT_REJECTED"
                result.failure_reason = (error as? AuthPreflightError)?.rawValue ?? "HARNESS_ERROR"
                result.statuses["AUTHENTICATED_PROFILE_ACCESS"] = "BLOCKED"
            }
        }
        guard let folder = environment["PAGINATION_EVIDENCE_DIR"] else { throw PaginationFailure.scope }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: folder).appendingPathComponent("pagination-result.json"), options: .atomic)
        return result.pipeline_completed && result.failure_category == nil
    }
}
