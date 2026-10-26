import Foundation
import DouStudioKit

enum IntegrationError: String, Error {
    case consent = "CONSENT_REQUIRED", profile = "PROFILE_REJECTED", credential = "SYNTHETIC_CREDENTIAL_MISSING"
    case index = "INDEX_REJECTED", kind = "NON_VIDEO_REJECTED", units = "MEDIA_UNIT_COUNT_REJECTED"
    case host = "HOST_SCOPE_REJECTED", listLimit = "SECOND_LIST_REQUEST_REJECTED", list = "LIST_RESPONSE_REJECTED"
    case restricted = "ACCESS_RESTRICTED", rate = "RATE_LIMITED", outcome = "DOWNLOAD_OUTCOME_REJECTED"
    case file = "FILE_INTEGRITY_ERROR", container = "MP4_CONTAINER_REJECTED", track = "VIDEO_TRACK_MISSING"
    case decode = "MEDIA_DECODE_FAILED", fixture = "FIXTURE_GENERATION_FAILED", cleanup = "CLEANUP_FAILED"
}

enum IntegrationPolicy {
    // Deliberately empty: no production host was independently audited. There is
    // no CLI/environment switch to populate it or to open the real-download gate.
    static let auditedProductionHosts: Set<String> = []
    static func profile(_ text: String, authorized: Bool, credentialPresent: Bool) throws -> String {
        guard authorized else { throw IntegrationError.consent }
        guard credentialPresent else { throw IntegrationError.credential }
        guard let url = URL(string:text), url.scheme == "https", url.host == "www.douyin.com",
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let parsed = LinkParser().parse(text), !parsed.requiresExpansion,
              case .user(let id, let modal) = parsed.target, modal == nil, !id.isEmpty, id.count <= 256,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              url.path == "/user/" + id else { throw IntegrationError.profile }
        return id
    }
    static func select(_ works: [DouyinWork], index: Int) throws -> DouyinWork {
        guard works.indices.contains(index) else { throw IntegrationError.index }
        let work = works[index]
        guard work.kind == .video else { throw IntegrationError.kind }
        guard work.downloads.count == 1, case .media = work.downloads[0] else { throw IntegrationError.units }
        return work
    }
    static func httpsHost(_ url: URL, approved: Set<String>) throws {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443, let host = url.host, approved.contains(host) else { throw IntegrationError.host }
    }
    // The only executable integration path: exact local fixture endpoint, with no
    // fallback to HTTPS production. The URL must still be Extractor output.
    static func fixtureURL(_ work: DouyinWork, port: Int, caseID: String) throws -> URL {
        guard case .media(let value) = work.downloads[0], let url = URL(string:value),
              url.scheme == "http", url.host == "127.0.0.1", url.port == port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/media/" + caseID else { throw IntegrationError.host }
        return url
    }
}

/// Exercises the ORIGINAL endpoint and signing pipeline but replaces its network
/// destination with one fixed loopback list fixture. No signed URL/parameters are
/// sent to the server or recorded. This adapter has no external-network path.
final class FixtureNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
actor IntegrationListTransport: HTTPTransport {
    static let syntheticCookie = "integration_fixture=synthetic_only"
    let port: Int
    let caseID: String
    private(set) var requests = 0
    private(set) var rejectedSecond = 0
    private(set) var credentialPresent = false
    init(port: Int, caseID: String) { self.port = port; self.caseID = caseID }
    func send(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        guard requests == 0 else { rejectedSecond += 1; throw IntegrationError.listLimit }
        guard request.method == .get, request.body == nil, options.proxy == nil, options.extraHeaders.isEmpty,
              let url = request.url, url.scheme == "https", url.host == "www.douyin.com",
              url.path == "/aweme/v1/web/aweme/post/", let components = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw IntegrationError.host }
        let query = components.queryItems ?? []
        for (key, value) in [("sec_user_id","fixture_user"),("max_cursor","0"),("count","18")] {
            let matches = query.filter { $0.name == key }
            guard matches.count == 1, matches[0].value == value else { throw IntegrationError.list }
        }
        guard request.headers.first(where: { $0.key.lowercased() == "cookie" })?.value == Self.syntheticCookie else { throw IntegrationError.credential }
        requests = 1; credentialPresent = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration:configuration,delegate:FixtureNoRedirect(),delegateQueue:nil); defer { session.invalidateAndCancel() }
        var local = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/list/\(caseID)")!,timeoutInterval:5)
        local.setValue(Self.syntheticCookie,forHTTPHeaderField:"Cookie")
        let (data, response) = try await session.data(for:local)
        guard let http = response as? HTTPURLResponse else { throw IntegrationError.list }
        if http.statusCode == 403 { throw IntegrationError.restricted }
        if http.statusCode == 429 { throw IntegrationError.rate }
        guard http.statusCode == 200, data.count <= 16384,
              let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              object["status_code"] as? Int == 0, object["aweme_list"] is [[String:Any]] else { throw IntegrationError.list }
        return HTTPResponse(statusCode:200,headers:["Content-Type":"application/json"],body:data)
    }
}
