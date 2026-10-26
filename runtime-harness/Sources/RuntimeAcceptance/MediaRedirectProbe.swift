import Foundation
import DouStudioKit

enum RedirectProbePolicy {
    static let www = "www.douyin.com"
    static let sf11 = "sf11-cdn-tos.douyinstatic.com"
    static let targetHost = "v5-dy-ov-experiment.zjcdn.com"
    static func absoluteLocation(_ value: String?) -> URL? {
        guard let value, value.utf8.count <= 16384,
              let parts = URLComponents(string:value), parts.scheme?.lowercased() == "https", parts.host != nil,
              MediaHostAudit.describe(value,id:"NEXT",alias:"NEXT",role:"video_playback",field:"location",selected:false).url_shape == "CANDIDATE_ONLY" else { return nil }
        return parts.url
    }
    static func targetAllowed(_ url: URL) -> Bool {
        absoluteLocation(url.absoluteString) != nil && url.host?.lowercased() == targetHost
    }
    static func classification(_ observation: LiveProbeObservation) -> String {
        if [403,429].contains(observation.http_status ?? 0) || observation.result == "AUTH_CHALLENGE_REJECTED" || observation.result == "TLS_ERROR" { return "BLOCKED" }
        if ["HTML","JSON"].contains(observation.content_type) { return "NON_MEDIA" }
        switch observation.result {
        case "VIDEO_RANGE_206_ONE_BYTE": return "DIRECT_MEDIA"
        case "HTTP_REDIRECT_NOT_FOLLOWED": return "REDIRECT"
        case "NON_VIDEO_RESPONSE": return "NON_MEDIA"
        case "ACCESS_RESTRICTED","RATE_LIMITED","AUTH_CHALLENGE_REJECTED","REQUEST_SCOPE_REJECTED",
             "PINNED_TUNNEL_NOT_VERIFIED","DNS_LOOKUP_FAILED","NON_PUBLIC_OR_UNSUPPORTED_ADDRESS",
             "PINNED_TUNNEL_FAILED","REDIRECT_POLICY_REJECTED": return "BLOCKED"
        default: return "INCONCLUSIVE"
        }
    }
}

enum RedirectProbeRole: String, Codable, Sendable, CaseIterable, Hashable { case www, target, sf11 }
struct RedirectRequestBudget {
    private(set) var reserved: Set<RedirectProbeRole> = []
    mutating func reserve(_ role: RedirectProbeRole) -> Bool {
        guard !reserved.contains(role), reserved.count < 3,
              role != .target || reserved.contains(.www) else { return false }
        reserved.insert(role); return true
    }
}
struct RedirectHopEvidence: Codable, Sendable {
    let role: RedirectProbeRole
    var observation: LiveProbeObservation
    var network_target_check = "NOT_REQUIRED_FOR_ORIGINAL_SCOPE"
    var dns_address_count = 0
    var tunnel: PinnedTunnelEvidence?
}
struct RedirectProbeExchange: Sendable {
    var evidence: RedirectHopEvidence
    var location: URL? // Memory only; no Codable or diagnostic description.
}
protocol RedirectProbeExecutor: Sendable {
    func execute(_ role: RedirectProbeRole, url: URL) async -> RedirectProbeExchange
}
struct ProductionRedirectExecutor: RedirectProbeExecutor {
    func execute(_ role: RedirectProbeRole, url: URL) async -> RedirectProbeExchange {
        if role != .target {
            let task = LiveProbeTask(host:role == .www ? RedirectProbePolicy.www : RedirectProbePolicy.sf11,captureLocation:role == .www)
            let result = await task.run(url)
            return RedirectProbeExchange(evidence:RedirectHopEvidence(role:role,observation:result),location:task.takeLocation())
        }
        var result = RedirectHopEvidence(role:.target,observation:LiveProbeObservation(host:RedirectProbePolicy.targetHost))
        do {
            let destination = try await RedirectNetworkSafety.resolve(url)
            result.dns_address_count = destination.addressCount
            let tunnel = try await PinnedProbeTunnel.start(destination)
            result.observation = await LiveProbeTask(host:RedirectProbePolicy.targetHost,scope:.redirectTarget,proxyPort:tunnel.port).run(url)
            let end = await tunnel.finish(); result.tunnel = end
            guard end.connect_authority_matched, end.outbound_connections == 1,
                  end.public_address_pinned, !end.credential_headers_seen, end.stopped else {
                result.network_target_check = "BLOCKED_PINNING_NOT_VERIFIED"
                result.observation.result = "PINNED_TUNNEL_NOT_VERIFIED"
                return RedirectProbeExchange(evidence:result,location:nil)
            }
            result.network_target_check = "PASS_PUBLIC_DNS_AND_NUMERIC_ADDRESS_PIN"
        } catch {
            result.network_target_check = "BLOCKED"
            result.observation.result = (error as? RedirectProbeError)?.rawValue ?? "PINNED_TUNNEL_FAILED"
        }
        return RedirectProbeExchange(evidence:result,location:nil)
    }
}

struct RedirectSampleCoverage: Codable, Sendable {
    var www_selected_source_count = 0
    var sf11_selected_source_count = 0
    var www_sample_status = "NO_ELIGIBLE_SAMPLE"
    var sf11_sample_status = "NO_ELIGIBLE_SAMPLE"
    var sf11_reason = "NO_SELECTED_HOST_SAMPLE"
}
struct RedirectSelectedSamples {
    let www: URL?, sf11: URL?
    let coverage: RedirectSampleCoverage
}

@MainActor enum MediaRedirectProbe {
    static func select(_ items: [JSONNode]) throws -> RedirectSelectedSamples {
        let collection = SelectedHostEvidence.collect(items)
        guard collection.complete else { throw AuthPreflightError.response }
        let chosen: [(String,URL)]
        do { chosen = try LiveProbePolicy.select(items) }
        catch AuthPreflightError.scope { chosen = [] }
        catch { throw error }
        var coverage = RedirectSampleCoverage()
        coverage.www_selected_source_count = collection.hosts.first { $0.host == RedirectProbePolicy.www }?.selected_work_count ?? 0
        coverage.sf11_selected_source_count = collection.hosts.first { $0.host == RedirectProbePolicy.sf11 }?.selected_work_count ?? 0
        let www = chosen.first { $0.0 == RedirectProbePolicy.www }?.1
        let sf11 = chosen.first { $0.0 == RedirectProbePolicy.sf11 }?.1
        if www != nil { coverage.www_sample_status = "SELECTED" }
        if sf11 != nil { coverage.sf11_sample_status = "SELECTED"; coverage.sf11_reason = "ELIGIBLE_ORIGINAL_SELECTION" }
        else if coverage.sf11_selected_source_count > 0 { coverage.sf11_reason = "SELECTION_POLICY_REJECTED" }
        return RedirectSelectedSamples(www:www,sf11:sf11,coverage:coverage)
    }
    struct Outcome: Codable {
        let TASK = "DOUSTUDIOKIT_MEDIA_REDIRECT_PROBE_02"
        var WWW_INITIAL_RESPONSE = "NOT_RUN"
        var WWW_REDIRECT_HOST: String?
        var REDIRECT_TARGET_PROBE = "NOT_RUN"
        var SF11_PROBE = "NOT_RUN"
        var MEDIA_REQUEST_COUNT = 0
        let MEDIA_RETRIES = 0
        let UNAPPROVED_REDIRECT_FOLLOWED = "NO"
        let FULL_VIDEO_DOWNLOADED = "NO"
        let HOST_SECURITY_REVIEW = "BLOCKED"
        let PRODUCTION_ALLOWLIST = "EMPTY"
        let NO_WATERMARK = "NOT_TESTED"
        let RUST_IMPLEMENTATION = "NOT_STARTED"
        let STRICT_NETWORK_RECEIVE_LIMIT = "NOT_PROVEN"
        var worklist = AuthObservation()
        var samples = RedirectSampleCoverage()
        var hops: [RedirectHopEvidence] = []
        var failure_category: String?
        var completed = false
    }
    // Shared live/fixture orchestration. Only the live executor resolves DNS or creates a pinned production tunnel.
    static func probe(_ samples: RedirectSelectedSamples, executor: any RedirectProbeExecutor) async -> Outcome {
        var output = Outcome(); output.samples = samples.coverage
        var budget = RedirectRequestBudget()
        if let www = samples.www, budget.reserve(.www) {
            let first = await executor.execute(.www,url:www)
            output.hops.append(first.evidence)
            let observation = first.evidence.observation
            output.WWW_INITIAL_RESPONSE = observation.request_count == 0 ? "NOT_RUN" : ((300..<400).contains(observation.http_status ?? 0) ? "REDIRECT" : "OTHER")
            output.WWW_REDIRECT_HOST = observation.redirect_host
            if observation.http_status == 302, observation.result == "HTTP_REDIRECT_NOT_FOLLOWED",
               observation.completion_callbacks == 1, observation.cancel_completed {
                if let location = first.location, RedirectProbePolicy.targetAllowed(location), budget.reserve(.target) {
                    let next = await executor.execute(.target,url:location)
                    output.hops.append(next.evidence)
                    output.REDIRECT_TARGET_PROBE = RedirectProbePolicy.classification(next.evidence.observation)
                    // A redirect here is only recorded. No code path can reserve or execute a third hop.
                } else { output.REDIRECT_TARGET_PROBE = "BLOCKED" }
            }
        }
        // Independent sf11 chain: a failure or redirect in the www chain cannot consume its slot.
        if let sf11 = samples.sf11, budget.reserve(.sf11) {
            let direct = await executor.execute(.sf11,url:sf11)
            output.hops.append(direct.evidence)
            output.SF11_PROBE = RedirectProbePolicy.classification(direct.evidence.observation)
        }
        output.MEDIA_REQUEST_COUNT = output.hops.reduce(0) { $0 + $1.observation.request_count }
        output.completed = true
        return output
    }
    static func publish(_ output: Outcome, folder: URL) throws {
        try MediaHostAudit.write(output,"probe-summary.json",folder)
        try MediaHostAudit.write(output.hops,"hop-observations.json",folder)
        try MediaHostAudit.write(output.samples,"sample-coverage.json",folder)
        try MediaHostAudit.write(output.hops.filter { $0.role == .target },"network-target-safety.json",folder)
        try MediaHostAudit.write(["worklist":output.worklist.request_count,"media":output.MEDIA_REQUEST_COUNT,
            "www":output.hops.filter { $0.role == .www }.reduce(0) { $0 + $1.observation.request_count },
            "target":output.hops.filter { $0.role == .target }.reduce(0) { $0 + $1.observation.request_count },
            "sf11":output.hops.filter { $0.role == .sf11 }.reduce(0) { $0 + $1.observation.request_count }],"request-count-results.json",folder)
        try MediaHostAudit.write([String](),"approved-hosts.json",folder)
    }
    static func run(_ env: [String:String]) async throws -> Bool {
        guard let path = env["REDIRECT_EVIDENCE_DIR"] else { return false }
        var output = Outcome(), observer: AuthPreflightTransport?
        do {
            guard env["REDIRECT_OFFLINE_VERIFIED"] == "true" else { throw AuthPreflightError.scope }
            let input = try AuthPreflightInput.validate(consent:env["REDIRECT_CONSENT"] == "true",cookie:env["DOUYIN_COOKIE"] ?? "",profile:env["REDIRECT_PROFILE"] ?? "")
            let transport = AuthPreflightTransport(input:input,base:URLSessionTransport()); observer = transport
            let config = KernelConfiguration(storageTargets:[],pageSize:18,maxPages:1,maxConcurrency:1,maxRetry:0,timeout:30,preferOriginalQuality:false)
            let client = try await DouyinClient(configuration:config,cookie:input.cookie,transport:transport,logger:.disabled)
            let endpoints = await client.endpoints
            let page = try await endpoints.accountTimeline(secUid:input.userID,tab:.post,page:PageRequest(count:18,maxPages:1,cursor:0))
            output = await probe(try select(page.works),executor:ProductionRedirectExecutor())
        } catch { output.failure_category = (error as? AuthPreflightError)?.rawValue ?? "SANITIZED_REDIRECT_PROBE_ERROR" }
        if let observer { output.worklist = await observer.snapshot() }
        try publish(output,folder:URL(fileURLWithPath:path))
        return output.completed && output.failure_category == nil
    }
}
