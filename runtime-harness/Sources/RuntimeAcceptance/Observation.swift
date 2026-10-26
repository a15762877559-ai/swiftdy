import Foundation
import CoreFoundation
import CryptoKit
import DouStudioKit

struct AcceptanceStop: Error, Sendable {
    let code: String
    let blocked: Bool
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func safeHTTPS(_ value: String) -> URL? {
    guard let c = URLComponents(string: value), c.scheme == "https",
          let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
          c.port == nil || c.port == 443, c.fragment == nil else { return nil }
    return c.url
}

func integer(_ value: Any?) -> Int64? {
    if let text = value as? String { return Int64(text) }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return Int64(number.stringValue)
    }
    return nil
}

struct FieldRecord: Codable, Sendable {
    let id: String
    let idValid: Bool
    let descriptionPresent: Bool
    let descriptionLength: Int
    let timestampValid: Bool
    let coverURLValid: Bool
    let videoURLValid: Bool
    let videoExpected: Bool
    var complete: Bool {
        idValid && descriptionPresent && timestampValid && coverURLValid && (!videoExpected || videoURLValid)
    }
}

struct PageRecord: Codable, Sendable {
    let page: Int
    let requestCursor: String
    let nextCursor: String?
    let hasMore: Bool?
    let count: Int
    let cumulativeCount: Int
    let uniqueCount: Int
    let duplicateIDs: Int
    let cursorValid: Bool
    let cursorStalled: Bool
    let error: String?
}

struct ExchangeRecord: Codable, Sendable {
    let kind: String
    let status: Int
    let bytes: Int
}

struct Observation: Sendable {
    let pages: [PageRecord]
    let fields: [FieldRecord]
    let exchanges: [ExchangeRecord]
    let candidate: DouyinWork?
    let mediaBytes: Int?
    let mediaHash: String?
}

/// Observes the public transport seam. All request construction, signing,
/// collection, extraction and file writing remain in the upstream library.
actor ObservingTransport: HTTPTransport {
    private let base: any HTTPTransport
    private var pages: [PageRecord] = []
    private var fields: [FieldRecord] = []
    private var exchanges: [ExchangeRecord] = []
    private var ids: Set<String> = []
    private var cursors: Set<Int64> = [0]
    private var expectedCursor: Int64 = 0
    private var apiRequests = 0
    private var cumulative = 0
    private var candidate: DouyinWork?
    private var allowedMedia: String?
    private var mediaRequests = 0
    private var mediaBytes: Int?
    private var mediaHash: String?

    init(base: any HTTPTransport = URLSessionTransport()) { self.base = base }

    func snapshot() -> Observation {
        Observation(pages: pages, fields: fields, exchanges: exchanges,
                    candidate: candidate, mediaBytes: mediaBytes, mediaHash: mediaHash)
    }

    func allowMedia(_ value: String) throws {
        guard let url = safeHTTPS(value), let host = url.host?.lowercased(),
              ["douyinvod.com", "douyin.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { throw AcceptanceStop(code: "MEDIA_HOST_OUTSIDE_ALLOWLIST", blocked: true) }
        allowedMedia = value
    }

    func send(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        do { return try await sendChecked(request, options: options) }
        catch {
            if apiRequests > pages.count {
                let code = (error as? AcceptanceStop)?.code ?? "REDACTED_ERROR"
                pages.append(PageRecord(page: apiRequests, requestCursor: String(expectedCursor),
                    nextCursor: nil, hasMore: nil, count: 0, cumulativeCount: cumulative,
                    uniqueCount: ids.count, duplicateIDs: 0, cursorValid: false,
                    cursorStalled: false, error: code))
            }
            throw error
        }
    }

    private func sendChecked(_ request: SignedRequest, options: TransportOptions) async throws -> HTTPResponse {
        guard request.method == .get, request.body == nil,
              !request.headers.contains(where: {
                  ["cookie", "authorization"].contains($0.key.lowercased()) && !$0.value.isEmpty
              }), options.extraHeaders.isEmpty, options.proxy == nil,
              let url = request.url, safeHTTPS(url.absoluteString) != nil else {
            throw AcceptanceStop(code: "REQUEST_SCOPE_REJECTED", blocked: true)
        }
        let api = url.host == "www.douyin.com" && url.path == "/aweme/v1/web/aweme/post/"
        var requestCursor: Int64 = 0
        if api {
            guard apiRequests < 3, pages.last?.hasMore != false else {
                throw AcceptanceStop(code: "PAGE_LIMIT_OR_EXHAUSTED", blocked: false)
            }
            // Read only the cursor; never persist or log the signed query.
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let value = query.first(where: { $0.name == "max_cursor" })?.value,
                  let cursor = Int64(value), cursor == expectedCursor else {
                throw AcceptanceStop(code: "REQUEST_CURSOR_MISMATCH", blocked: false)
            }
            requestCursor = cursor
            apiRequests += 1
        } else {
            guard request.url?.absoluteString == allowedMedia, mediaRequests == 0 else {
                throw AcceptanceStop(code: "UNEXPECTED_REQUEST_OR_DOWNLOAD_LIMIT", blocked: true)
            }
            mediaRequests += 1
        }
        // Refuse redirects, including redirects to login pages or unknown hosts.
        var bounded = options
        bounded.followRedirects = false
        bounded.timeout = api ? 30 : 120
        let response: HTTPResponse
        do { response = try await base.send(request, options: bounded) }
        catch { throw AcceptanceStop(code: "TRANSPORT_ERROR", blocked: false) }
        exchanges.append(ExchangeRecord(kind: api ? "worklist" : "media",
                                        status: response.statusCode, bytes: response.body.count))
        guard response.statusCode == 200 else {
            throw AcceptanceStop(code: "HTTP_\(response.statusCode)",
                                 blocked: [401, 403, 404, 429].contains(response.statusCode) || (300..<400).contains(response.statusCode))
        }
        if api { try observePage(response.body, requestCursor: requestCursor) }
        else {
            let type = response.headers.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased() ?? ""
            guard !type.contains("html"), !type.contains("json"), !response.body.isEmpty else {
                throw AcceptanceStop(code: "NON_MEDIA_RESPONSE", blocked: true)
            }
            if let text = response.headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
               let length = Int(text), length != response.body.count {
                throw AcceptanceStop(code: "MEDIA_LENGTH_MISMATCH", blocked: false)
            }
            // Upstream's downloader buffers a response; this is a post-receive
            // size guard, not a streaming bandwidth limit.
            guard response.body.count <= 100 * 1024 * 1024 else {
                throw AcceptanceStop(code: "MEDIA_OVER_100_MIB", blocked: true)
            }
            guard response.body.count >= 12,
                  String(data: response.body.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else {
                throw AcceptanceStop(code: "MEDIA_CONTAINER_NOT_MP4", blocked: false)
            }
            mediaBytes = response.body.count
            mediaHash = digest(response.body)
        }
        return response
    }

    private func observePage(_ body: Data, requestCursor: Int64) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw AcceptanceStop(code: "NON_JSON_POSSIBLE_ACCESS_CHALLENGE", blocked: true)
        }
        guard let status = integer(object["status_code"]) else {
            throw AcceptanceStop(code: "MISSING_PLATFORM_STATUS", blocked: false)
        }
        guard status == 0 else {
            throw AcceptanceStop(code: "PLATFORM_STATUS_\(status)", blocked: true)
        }
        guard let items = object["aweme_list"] as? [[String: Any]], items.count <= 50 else {
            throw AcceptanceStop(code: "NOT_A_WORK_LIST", blocked: false)
        }
        let hasMore: Bool?
        if let number = object["has_more"] as? NSNumber, ["0", "1"].contains(number.stringValue) {
            hasMore = number.boolValue
        } else { hasMore = nil }
        let next = integer(object["max_cursor"])
        let valid = next.map { $0 >= 0 } ?? false
        let stalled = hasMore == true && next.map { cursors.contains($0) } == true
        var duplicates = 0
        for raw in items {
            // Use the original public extractor, without copying its mapping.
            let work = DouyinExtractor(options: ExtractionOptions(preferOriginalQuality: false))
                .work(from: JSONNode(raw), collectionTime: "")
            let idValid = !work.id.isEmpty && work.id.count <= 30 && work.id.allSatisfy { $0.isASCII && $0.isNumber }
            if idValid && !ids.insert(work.id).inserted { duplicates += 1 }
            let video = work.downloads.contains { target in
                if case .media(let url) = target { return safeHTTPS(url) != nil }
                return false
            }
            fields.append(FieldRecord(id: idValid ? work.id : "INVALID", idValid: idValid,
                descriptionPresent: !work.desc.isEmpty, descriptionLength: work.desc.count,
                timestampValid: work.createTimestamp > 0 && work.createTimestamp <= Int(Date().timeIntervalSince1970) + 86400,
                coverURLValid: safeHTTPS(work.staticCover) != nil || safeHTTPS(work.dynamicCover) != nil,
                videoURLValid: video, videoExpected: work.kind == .video))
            let statusNode = raw["status"] as? [String: Any]
            // Missing visibility information is not treated as permission.
            let explicitlyPublic = integer(statusNode?["is_private"]) == 0
                && (statusNode?["is_delete"] as? Bool) != true
                && (statusNode?["is_prohibited"] as? Bool) != true
            if candidate == nil, explicitlyPublic, idValid, work.kind == .video,
               work.downloads.count == 1, video { candidate = work }
        }
        cumulative += items.count
        let error: String?
        if hasMore == nil || !valid { error = "MISSING_OR_INVALID_PAGINATION" }
        else if stalled { error = "CURSOR_STALLED_OR_CYCLIC" }
        else if hasMore == true && items.isEmpty { error = "EMPTY_PAGE_WITH_MORE" }
        else { error = nil }
        pages.append(PageRecord(page: pages.count + 1, requestCursor: String(requestCursor),
            nextCursor: next.map(String.init), hasMore: hasMore, count: items.count,
            cumulativeCount: cumulative, uniqueCount: ids.count, duplicateIDs: duplicates,
            cursorValid: valid, cursorStalled: stalled, error: error))
        if let error { throw AcceptanceStop(code: error, blocked: false) }
        if let next { expectedCursor = next; cursors.insert(next) }
    }
}
