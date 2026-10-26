import Foundation
import DouStudioKit

// Only host/role/ordinal/boolean/fixed-category evidence is Codable. Never retain URLs here.
struct MediaHostRecord: Codable {
    let evidence_id: String
    let work_alias: String
    let role: String
    let source_field: String
    let selected_by_original_extractor: Bool
    var normalized_host: String?
    var https = false
    var userinfo_present = false
    var nonstandard_port = false
    var ip_or_numeric_host = false
    var forbidden_local_or_reserved_name = false
    var url_shape = "REJECTED"
    var reason = "INVALID_URL"
    let dns_target_check = "NOT_VERIFIED_NO_DNS_LOOKUP"
    let redirect_risk = "UNKNOWN_NOT_REQUESTED_REDIRECTS_FORBIDDEN"
    let public_service_association = "NOT_REVIEWED"
    let approved = false
}

struct MediaHostCollection: Codable {
    var records: [MediaHostRecord] = []
    var truncated = false
    var selected_video_count = 0
    var selected_source_unmatched = 0
}

enum MediaHostAudit {
    static func describe(_ value: String, id: String, alias: String, role: String, field: String, selected: Bool) -> MediaHostRecord {
        var r = MediaHostRecord(evidence_id:id, work_alias:alias, role:role, source_field:field, selected_by_original_extractor:selected)
        guard value.utf8.count <= 16384, !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let c = URLComponents(string:value), let host = c.host, !host.isEmpty else { return r }
        r.https = c.scheme?.lowercased() == "https"
        r.userinfo_present = c.user != nil || c.password != nil
        r.nonstandard_port = c.port != nil && c.port != 443
        let lower = host.lowercased()
        // Do not serialize arbitrary authority text. ASCII host grammar only; reject IDN ambiguity.
        guard lower.utf8.count <= 253,
              lower.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-:[]".unicodeScalars.contains($0)) }) else {
            r.reason = "HOST_SYNTAX_REJECTED"; return r
        }
        r.normalized_host = lower
        let labels = lower.split(separator: ".", omittingEmptySubsequences:false)
        r.ip_or_numeric_host = lower.contains(":") || labels.allSatisfy { label in
            label.allSatisfy(\.isNumber) || label.hasPrefix("0x")
        }
        let reserved = ["localhost","local","internal","lan","home","test","invalid","example","onion","arpa"]
        r.forbidden_local_or_reserved_name = labels.count < 2 || reserved.contains { lower == $0 || lower.hasSuffix("." + $0) }
        guard r.https else { r.reason = "HTTPS_REQUIRED"; return r }
        guard !r.userinfo_present else { r.reason = "USERINFO_REJECTED"; return r }
        guard !r.nonstandard_port else { r.reason = "PORT_REJECTED"; return r }
        guard !r.ip_or_numeric_host else { r.reason = "IP_LITERAL_OR_NUMERIC_HOST_REJECTED"; return r }
        guard !r.forbidden_local_or_reserved_name else { r.reason = "LOCAL_OR_RESERVED_NAME_REJECTED"; return r }
        guard c.fragment == nil, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              labels.last?.contains(where: \.isLetter) == true, !lower.contains("xn--") else {
            r.reason = "HOST_SYNTAX_REJECTED"; return r
        }
        r.url_shape = "CANDIDATE_ONLY"
        r.reason = role == "video_playback" ? "INDEPENDENT_HOST_REVIEW_REQUIRED" : "NON_VIDEO_RESOURCE_EXCLUDED"
        return r
    }

    static func collect(_ items: [JSONNode]) -> MediaHostCollection {
        var output = MediaHostCollection()
        for (index,item) in items.prefix(50).enumerated() {
            let alias = String(format:"WORK-%03d",index + 1) // Run-local ordinal; no real ID or ID hash.
            let work = DouyinExtractor(options:ExtractionOptions(preferOriginalQuality:false)).work(from:item,collectionTime:"")
            var selected: String?
            if work.kind == .video, work.downloads.count == 1, case .media(let value) = work.downloads[0] {
                selected = value; output.selected_video_count += 1
            }
            var matched = false
            func append(_ nodes: [JSONNode], field: String, role: String) {
                if nodes.count > 20 { output.truncated = true }
                for (n,node) in nodes.prefix(20).enumerated() {
                    guard let value = node.raw as? String else { continue }
                    guard output.records.count < 1000 else { output.truncated = true; continue }
                    let activeField = field.hasPrefix("video.bit_rate[") == !item.nodes("video.bit_rate").isEmpty
                    let chosen = role == "video_playback" && activeField && selected == value
                    if chosen { matched = true }
                    output.records.append(describe(value,id:String(format:"HOST-%04d",output.records.count + 1),alias:alias,
                        role:role,field:field + "[\(n)]",selected:chosen))
                }
            }
            // Classify image/live-photo video subfields separately; never eligible video candidates.
            let playRole = work.kind == .video ? "video_playback" : "non_video_work_resource"
            append(item.nodes("video.play_addr.url_list"),field:"video.play_addr.url_list",role:playRole)
            let rates = item.nodes("video.bit_rate")
            if rates.count > 50 { output.truncated = true }
            for (n,rate) in rates.prefix(50).enumerated() {
                append(rate.nodes("play_addr.url_list"),field:"video.bit_rate[\(n)].play_addr.url_list",role:playRole)
            }
            for field in ["video.cover.url_list","video.dynamic_cover.url_list","video.origin_cover.url_list"] {
                append(item.nodes(field),field:field,role:"cover_image")
            }
            for field in ["author.avatar_thumb.url_list","author.avatar_medium.url_list","author.avatar_larger.url_list"] {
                append(item.nodes(field),field:field,role:"avatar_image")
            }
            append(item.nodes("music.play_url.url_list"),field:"music.play_url.url_list",role:"other_audio")
            if selected != nil && !matched { output.selected_source_unmatched += 1 }
        }
        if items.count > 50 { output.truncated = true }
        return output
    }

    static func write<T: Encodable>(_ value: T, _ name: String, _ folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try encoder.encode(value).write(to:folder.appendingPathComponent(name),options:.atomic)
    }

    @MainActor static func run(environment env: [String:String]) async throws -> Bool {
        guard let path = env["HOST_EVIDENCE_DIR"] else { return false }
        let folder = URL(fileURLWithPath:path,isDirectory:true)
        let cookie = env["DOUYIN_COOKIE"] ?? ""
        var observer: AuthPreflightTransport?
        var collection = MediaHostCollection()
        var failure: String?
        var succeeded = false
        do {
            let input = try AuthPreflightInput.validate(consent:env["HOST_CONSENT"] == "true",cookie:cookie,profile:env["HOST_PROFILE"] ?? "")
            let transport = AuthPreflightTransport(input:input,base:URLSessionTransport()); observer = transport
            let config = KernelConfiguration(storageTargets:[],pageSize:18,maxPages:1,maxConcurrency:1,maxRetry:0,timeout:30,preferOriginalQuality:false)
            let client = try await DouyinClient(configuration:config,cookie:input.cookie,transport:transport,logger:.disabled)
            let endpoints = await client.endpoints
            let page = try await endpoints.accountTimeline(secUid:input.userID,tab:.post,page:PageRequest(count:18,maxPages:1,cursor:0))
            collection = collect(page.works)
            succeeded = !collection.truncated && collection.selected_source_unmatched == 0 && collection.selected_video_count > 0
            if !succeeded { failure = "INCOMPLETE_OR_NO_VIDEO_HOST_EVIDENCE" }
        } catch { failure = (error as? AuthPreflightError)?.rawValue ?? "SANITIZED_AUDIT_ERROR" }
        let observation = await observer?.snapshot() ?? AuthObservation()
        struct Summary: Codable {
            let credential_present: Bool
            let observation: AuthObservation
            let collection_completed: Bool
            let failure_category: String?
            let truncated: Bool
            let selected_video_count: Int
            let selected_source_unmatched: Int
            let MEDIA_HOSTS_IDENTIFIED: String
            let HOST_PROVENANCE: String
            let HOST_SECURITY_REVIEW = "BLOCKED"
            let PRODUCTION_ALLOWLIST = "EMPTY"
            let APPROVED_HOSTS = 0
            let REAL_MEDIA_REQUEST = "NOT_RUN"
            let REAL_VIDEO_DOWNLOAD = "NOT_RUN"
            let APPLICATION_BYTE_BUDGET = "PASS"
            let byte_budget_evidence_run = "40289436585"
            let STRICT_NETWORK_RECEIVE_LIMIT = "NOT_PROVEN"
        }
        try write(collection.records.filter { $0.role == "video_playback" },"candidate-hosts.json",folder)
        try write(collection,"host-provenance.json",folder)
        try write(collection.records,"host-security-review.json",folder)
        try write([String](),"approved-hosts.json",folder) // Never auto-promote a response host.
        try write(Summary(credential_present:!cookie.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
            observation:observation,collection_completed:succeeded,failure_category:failure,truncated:collection.truncated,
            selected_video_count:collection.selected_video_count,selected_source_unmatched:collection.selected_source_unmatched,
            MEDIA_HOSTS_IDENTIFIED:collection.records.contains(where: { $0.role == "video_playback" && $0.normalized_host != nil }) ? "YES" : "NO",
            HOST_PROVENANCE:succeeded ? "PASS" : "PARTIAL"),"audit-summary.json",folder)
        return succeeded
    }
}
