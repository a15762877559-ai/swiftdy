import Foundation
import DouStudioKit

enum AuthPreflightError: String, Error, Hashable {
    case consent = "AUTHORIZATION_REQUIRED"
    case missing = "CREDENTIAL_MISSING"
    case credential = "CREDENTIAL_CONFIGURATION_REJECTED"
    case profile = "PROFILE_PARSE_ERROR"
    case scope = "REQUEST_SCOPE_REJECTED"
    case limit = "SINGLE_REQUEST_LIMIT"
    case network = "NETWORK_ERROR"
    case access = "ACCESS_RESTRICTED"
    case rate = "RATE_LIMITED"
    case challenge = "CHALLENGE_REQUIRED"
    case response = "API_RESPONSE_CHANGED"
    case empty = "EMPTY_LIST_NOT_ACCEPTANCE_PROOF"
    case unknown = "UNKNOWN"
}

struct AuthPreflightInput: Sendable {
    let cookie: String // Memory only; never Codable, printed, hashed or written.
    let userID: String

    static func validate(consent: Bool, cookie: String, profile: String) throws -> Self {
        guard consent else { throw AuthPreflightError.consent }
        guard !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AuthPreflightError.missing }
        guard !cookie.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AuthPreflightError.credential
        }
        guard let url = safeHTTPS(profile), url.host == "www.douyin.com", url.query == nil,
              let link = LinkParser().parse(profile), !link.requiresExpansion,
              case .user(let id, let modal) = link.target, modal == nil,
              !id.isEmpty, id.count <= 256,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == "/user/" + id else {
            throw AuthPreflightError.profile
        }
        return Self(cookie: cookie, userID: id)
    }
}

struct AuthObservation: Codable, Sendable {
    var request_started = false
    var request_count = 0
    var http_status: Int?
    var request_succeeded = false
    var valid_worklist = false
    var item_count: Int?
    var fields: [String: Int] = [:]
}

/// Separate boundary: the anonymous ObservingTransport is not relaxed.
actor AuthPreflightTransport: HTTPTransport {
    private let input: AuthPreflightInput
    private let base: any HTTPTransport
    private var observed = AuthObservation()

    init(input: AuthPreflightInput, base: any HTTPTransport) {
        self.input = input; self.base = base
    }
    func snapshot() -> AuthObservation { observed }

    func send(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        guard observed.request_count == 0 else { throw AuthPreflightError.limit }
        guard request.method == .get, request.body == nil, options.extraHeaders.isEmpty,
              options.proxy == nil, let url = request.url, safeHTTPS(url.absoluteString) != nil,
              url.host == "www.douyin.com",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/aweme/v1/web/aweme/post/" else { throw AuthPreflightError.scope }
        let query = components.queryItems ?? []
        func only(_ key: String, _ value: String) -> Bool {
            let values = query.filter { $0.name == key }
            return values.count == 1 && values[0].value == value
        }
        let cookies = request.headers.filter { $0.key.lowercased() == "cookie" }
        guard only("max_cursor", "0"), only("count", "18"), only("sec_user_id", input.userID),
              cookies.count == 1, cookies.first?.value == input.cookie,
              !request.headers.keys.contains(where: { ["authorization", "proxy-authorization"].contains($0.lowercased()) }) else {
            throw AuthPreflightError.scope
        }
        // Reserve the only request before awaiting; even concurrent sends cannot pass.
        observed.request_count = 1; observed.request_started = true
        var bounded = options; bounded.followRedirects = false; bounded.timeout = 30
        let response: HTTPResponse
        do { response = try await base.send(request, options: bounded) }
        catch { throw AuthPreflightError.network } // Never emit upstream error text.
        observed.http_status = response.statusCode
        switch response.statusCode {
        case 200: observed.request_succeeded = true
        case 429: throw AuthPreflightError.rate
        case 401, 403, 404, 300..<400: throw AuthPreflightError.access
        default: throw AuthPreflightError.response
        }
        let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if contentType.contains("html") { throw AuthPreflightError.challenge }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw AuthPreflightError.challenge
        }
        guard let status = integer(object["status_code"]) else { throw AuthPreflightError.response }
        guard status == 0 else { throw AuthPreflightError.access }
        guard let items = object["aweme_list"] as? [[String: Any]], items.count <= 50 else { throw AuthPreflightError.response }
        observed.valid_worklist = true; observed.item_count = items.count
        var fields = ["id_valid": 0, "description_present": 0, "timestamp_valid": 0, "cover_present": 0, "video_present": 0]
        for raw in items {
            let work = DouyinExtractor(options: ExtractionOptions(preferOriginalQuality: false)).work(from: JSONNode(raw), collectionTime: "")
            if !work.id.isEmpty && work.id.count <= 30 && work.id.allSatisfy({ $0.isASCII && $0.isNumber }) { fields["id_valid", default: 0] += 1 }
            if !work.desc.isEmpty { fields["description_present", default: 0] += 1 }
            if work.createTimestamp > 0 && work.createTimestamp <= Int(Date().timeIntervalSince1970) + 86400 { fields["timestamp_valid", default: 0] += 1 }
            if safeHTTPS(work.staticCover) != nil || safeHTTPS(work.dynamicCover) != nil { fields["cover_present", default: 0] += 1 }
            if work.downloads.contains(where: { if case .media(let value) = $0 { return safeHTTPS(value) != nil }; return false }) { fields["video_present", default: 0] += 1 }
        }
        observed.fields = fields
        guard !items.isEmpty else { throw AuthPreflightError.empty }
        return response
    }
}

struct AuthPreflightResult: Codable {
    var credential_present: Bool
    var statuses = ["AUTH_PREFLIGHT": "NOT_RUN", "COOKIE_CONFIGURATION": "NOT_RUN", "PROFILE_RESOLUTION": "NOT_RUN",
                    "WORKLIST_FETCH": "NOT_RUN", "AUTHENTICATED_ACCESS_ACCEPTED": "UNKNOWN", "PAGINATION": "NOT_RUN",
                    "VIDEO_DOWNLOAD": "NOT_RUN", "SIGNATURE_REVERSE_ENGINEERING": "NOT_STARTED", "RUST_IMPLEMENTATION": "NOT_STARTED"]
    var observation = AuthObservation()
    var failure_category: String?
}

enum AuthenticatedPreflight {
    @MainActor static func run(environment: [String: String]) async throws -> Bool {
        let cookie = environment["DOUYIN_COOKIE"] ?? ""
        var result = AuthPreflightResult(credential_present: !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        var observer: AuthPreflightTransport?
        do {
            result.statuses["COOKIE_CONFIGURATION"] = result.credential_present ? "READY" : "MISSING"
            let input = try AuthPreflightInput.validate(consent: environment["AUTH_CONSENT"] == "true", cookie: cookie,
                                                       profile: environment["AUTH_PROFILE"] ?? "")
            result.statuses["PROFILE_RESOLUTION"] = "PASS"
            let transport = AuthPreflightTransport(input: input, base: URLSessionTransport())
            observer = transport
            let configuration = KernelConfiguration(storageTargets: [], pageSize: 18, maxPages: 1, maxConcurrency: 1,
                                                    maxRetry: 0, timeout: 30, preferOriginalQuality: false)
            let client = try await DouyinClient(configuration: configuration, cookie: input.cookie, transport: transport, logger: .disabled)
            let endpoints = await client.endpoints
            _ = try await endpoints.accountTimeline(secUid: input.userID, tab: .post, page: PageRequest(count: 18, maxPages: 1, cursor: 0))
            result.statuses["AUTH_PREFLIGHT"] = "PASS"
            result.statuses["WORKLIST_FETCH"] = "PASS"
            result.statuses["AUTHENTICATED_ACCESS_ACCEPTED"] = "YES"
        } catch {
            let category = error as? AuthPreflightError ?? .unknown
            result.failure_category = category.rawValue
            let blocked: Set<AuthPreflightError> = [.consent, .missing, .credential, .scope, .limit, .access, .rate, .challenge, .empty]
            result.statuses["AUTH_PREFLIGHT"] = blocked.contains(category) ? "BLOCKED" : "FAIL"
            if category == .profile { result.statuses["PROFILE_RESOLUTION"] = "FAIL" }
            if observer != nil { result.statuses["WORKLIST_FETCH"] = blocked.contains(category) ? "BLOCKED" : "FAIL" }
            if [.access, .rate, .challenge].contains(category) { result.statuses["AUTHENTICATED_ACCESS_ACCEPTED"] = "NO" }
        }
        if let observer { result.observation = await observer.snapshot() }
        guard let folder = environment["AUTH_EVIDENCE_DIR"] else { throw AuthPreflightError.scope }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: folder).appendingPathComponent("auth-result.json"), options: .atomic)
        return result.statuses["AUTH_PREFLIGHT"] == "PASS"
    }
}
