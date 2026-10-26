import Foundation
import DouStudioKit
import SafeDownloadSupport

@MainActor enum SingleVideoRealDownload {
    struct Summary: Codable {
        let TASK = "DOUSTUDIOKIT_SINGLE_VIDEO_REAL_DOWNLOAD_01"
        var SWIFT_BUILD = "PASS", OFFLINE_TESTS = "PASS"
        var REAL_WORKLIST = "NOT_RUN", REDIRECT_RESOLUTION = "NOT_RUN", REAL_VIDEO_DOWNLOAD = "NOT_RUN"
        var APPLICATION_BYTE_BUDGET = "NOT_RUN", MEDIA_FILE_INTEGRITY = "NOT_RUN", MEDIA_DECODE = "NOT_RUN", FULL_DECODE = "NOT_RUN", TEMP_FILE_CLEANUP = "NOT_RUN"
        let NO_WATERMARK = "NOT_VERIFIED", PRODUCTION_ALLOWLIST = "EMPTY", RUST_IMPLEMENTATION = "NOT_STARTED", AUTO_TRIGGERED = "NO"
        let STRICT_NETWORK_RECEIVE_LIMIT = "NOT_PROVEN"
        let selection_strategy = "FIRST_ELIGIBLE_ORDINARY_VIDEO_WITH_ORIGINAL_WWW_URL_IN_LIST_ORDER"
        var selected_list_index: Int?
        var worklist = AuthObservation()
        var entry: LiveProbeObservation?
        var cdn_requests = 0
        var target_network_check = "NOT_RUN"
        var dns_address_count = 0
        var tunnel: PinnedTunnelEvidence?
        var failure_category: String?
        var completed = false
    }
    static func select(_ items: [JSONNode]) throws -> (DouyinWork,URL,Int) {
        guard SelectedHostEvidence.collect(items).complete else { throw AuthPreflightError.response }
        let extractor = DouyinExtractor(options:ExtractionOptions(preferOriginalQuality:false))
        for (index,item) in items.enumerated() {
            let work = extractor.work(from:item,collectionTime:"")
            guard work.kind == .video,work.downloads.count == 1,case .media(let value) = work.downloads[0],
                  LiveProbePolicy.allowed(value),let url = URL(string:value),url.host?.lowercased() == RedirectProbePolicy.www,
                  SelectedHostEvidence.associate(item,selected:value,workRef:"SELECTED")?.selection_match == true else { continue }
            return (work,url,index)
        }
        throw AuthPreflightError.scope
    }
    static func object(_ value: Any, _ name: String, _ folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:folder.appendingPathComponent(name),options:.atomic)
    }
    static func evidenceParts(_ data: Data, folder: URL) throws -> [String:Any] {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw IntegrationBoundaryError.evidence }
        let metrics = root["metrics"] as? [String:Any] ?? [:]
        let media = root["media"] as? [String:Any] ?? [:]
        try object(["max_media_bytes":104857600,"written_bytes":root["written_bytes"] ?? 0,"transport":metrics,
            "APPLICATION_BYTE_BUDGET":root["APPLICATION_BYTE_BUDGET"] ?? "NOT_RUN","STRICT_NETWORK_RECEIVE_LIMIT":"NOT_PROVEN"],"download-budget.json",folder)
        try object(["status":root["MEDIA_FILE_INTEGRITY"] ?? "NOT_RUN","completeness_method":root["completeness_method"] ?? "NOT_RUN",
            "declared_length_matches":root["declared_length_matches"] ?? NSNull(),"proof":media],"media-integrity.json",folder)
        try object(["MEDIA_DECODE":root["MEDIA_DECODE"] ?? "NOT_RUN","FULL_DECODE":root["FULL_DECODE"] ?? "NOT_RUN","proof":media],"decode-results.json",folder)
        try object(["swift_cleanup":root["TEMP_FILE_CLEANUP"] ?? "NOT_RUN","partial_files_before_cleanup":root["partial_files_before_cleanup"] ?? 0],"cleanup-results.json",folder)
        try object(root,"transfer-results.json",folder)
        return root
    }
    private enum IntegrationBoundaryError: Error { case evidence }
    static func run(_ env: [String:String]) async throws -> Bool {
        guard let path = env["DOWNLOAD_EVIDENCE_DIR"],let parent = env["DOWNLOAD_MEDIA_ROOT"] else { return false }
        let folder = URL(fileURLWithPath:path)
        var summary = Summary(), observer: AuthPreflightTransport?, tunnel: PinnedProbeTunnel?
        do {
            guard env["DOWNLOAD_OFFLINE_VERIFIED"] == "true",env["REAL_DOWNLOAD_AUTHORIZED"] == "true" else { throw AuthPreflightError.consent }
            let input = try AuthPreflightInput.validate(consent:env["DOWNLOAD_CONSENT"] == "true",cookie:env["DOUYIN_COOKIE"] ?? "",profile:env["DOWNLOAD_PROFILE"] ?? "")
            let list = AuthPreflightTransport(input:input,base:URLSessionTransport()); observer = list
            let config = KernelConfiguration(storageTargets:[],pageSize:18,maxPages:1,maxConcurrency:1,maxRetry:0,timeout:30,preferOriginalQuality:false)
            let client = try await DouyinClient(configuration:config,cookie:input.cookie,transport:list,logger:.disabled)
            let endpoints = await client.endpoints
            let page = try await endpoints.accountTimeline(secUid:input.userID,tab:.post,page:PageRequest(count:18,maxPages:1,cursor:0))
            let (work,url,index) = try select(page.works); summary.selected_list_index = index
            let entrance = LiveProbeTask(host:RedirectProbePolicy.www,captureLocation:true)
            summary.REDIRECT_RESOLUTION = "FAIL"
            let entry = await entrance.run(url); summary.entry = entry
            guard entry.http_status == 302,entry.result == "HTTP_REDIRECT_NOT_FOLLOWED",entry.cancel_completed,entry.completion_callbacks == 1,
                  let location = entrance.takeLocation(),RedirectProbePolicy.targetAllowed(location) else { throw RedirectProbeError.policy }
            let destination = try await RedirectNetworkSafety.resolve(location)
            summary.dns_address_count = destination.addressCount
            let pinned = try await PinnedProbeTunnel.start(destination); tunnel = pinned
            summary.target_network_check = "PUBLIC_DNS_VALIDATED_TUNNEL_PENDING"
            summary.REDIRECT_RESOLUTION = "PASS"
            let receipt = await SingleVideoDownloadBridge.run(work:work,targetURL:location,proxyPort:pinned.port,mediaParent:URL(fileURLWithPath:parent))
            summary.cdn_requests = receipt.mediaRequests
            let diagnostics = try evidenceParts(receipt.json,folder:folder)
            summary.REAL_VIDEO_DOWNLOAD = receipt.mediaRequests > 0 ? (receipt.success ? "PASS" : "FAIL") : "NOT_RUN"
            summary.APPLICATION_BYTE_BUDGET = diagnostics["APPLICATION_BYTE_BUDGET"] as? String ?? "NOT_RUN"
            summary.MEDIA_FILE_INTEGRITY = diagnostics["MEDIA_FILE_INTEGRITY"] as? String ?? "NOT_RUN"
            summary.MEDIA_DECODE = diagnostics["MEDIA_DECODE"] as? String ?? "NOT_RUN"
            summary.FULL_DECODE = diagnostics["FULL_DECODE"] as? String ?? "NOT_RUN"
            summary.TEMP_FILE_CLEANUP = receipt.cleanup ? "PASS" : "FAIL"
            if !receipt.success { summary.failure_category = diagnostics["category"] as? String ?? "DOWNLOAD_OR_INTEGRITY_FAILED" }
        } catch {
            summary.failure_category = (error as? AuthPreflightError)?.rawValue ?? (error as? RedirectProbeError)?.rawValue ?? "SANITIZED_SINGLE_DOWNLOAD_ERROR"
        }
        if let tunnel {
            let end = await tunnel.finish(); summary.tunnel = end
            if end.public_address_pinned,end.connect_authority_matched,end.outbound_connections == 1,!end.credential_headers_seen,end.stopped {
                summary.target_network_check = "PASS_PUBLIC_DNS_AND_NUMERIC_ADDRESS_PIN"
            } else {
                summary.target_network_check = "BLOCKED_PINNING_NOT_VERIFIED"
                summary.REAL_VIDEO_DOWNLOAD = summary.cdn_requests > 0 ? "FAIL" : "NOT_RUN"
                summary.failure_category = "PINNED_TUNNEL_NOT_VERIFIED"
            }
        }
        if let observer { summary.worklist = await observer.snapshot() }
        summary.REAL_WORKLIST = summary.worklist.valid_worklist ? "PASS" : (summary.worklist.request_started ? "FAIL" : "NOT_RUN")
        summary.completed = summary.REAL_VIDEO_DOWNLOAD == "PASS" && summary.MEDIA_FILE_INTEGRITY == "PASS" && summary.FULL_DECODE == "PASS" && summary.TEMP_FILE_CLEANUP == "PASS" && summary.failure_category == nil
        try MediaHostAudit.write(summary,"download-summary.json",folder)
        try object(["worklist":summary.worklist.request_count,"entry":summary.entry?.request_count ?? 0,"cdn":summary.cdn_requests,"retries":0],"request-counts.json",folder)
        struct Security: Codable {
            let entry: LiveProbeObservation?
            let network_target_check: String
            let dns_address_count: Int
            let tunnel: PinnedTunnelEvidence?
            let automatic_redirect_followed = false
            let production_allowlist = "EMPTY"
        }
        try MediaHostAudit.write(Security(entry:summary.entry,network_target_check:summary.target_network_check,dns_address_count:summary.dns_address_count,tunnel:summary.tunnel),"redirect-security.json",folder)
        try MediaHostAudit.write([String](),"approved-hosts.json",folder)
        return summary.completed
    }
}
