import Foundation
import DouStudioKit

struct SelectedWorkEvidence: Codable {
    let work_ref: String
    let selected_host: String?
    let selected_source_paths: [String]
    let winning_source_paths: [String]
    let source_match_count: Int
    let selection_method: String
    let selection_match: Bool
    let match_status: String
    let scheme: String
    let port: Int?
    let userinfo_present: Bool
    let safety: MediaHostRecord
}
struct SelectedHostSummary: Codable {
    let host: String?
    var selected_work_count = 0
    var source_field_counts: [String:Int] = [:]
    var matched_work_count = 0
    var unmatched_work_count = 0
    let security_review_status = "BLOCKED_INDEPENDENT_REVIEW_REQUIRED"
}
struct AlternateHostSummary: Codable {
    let host: String?
    var occurrences = 0
    var source_field_counts: [String:Int] = [:]
    var work_refs: [String] = []
    let approved = false
}
struct MediaHostCollection: Codable {
    let schema_version = 2
    var selected: [SelectedWorkEvidence] = []
    var hosts: [SelectedHostSummary] = []
    var alternates: [AlternateHostSummary] = []
    var non_video_resource_counts: [String:Int] = [:]
    var errors: [String] = []
    var duplicate_work_count = 0
    var alternate_urls_examined = 0
    var ALTERNATE_SUMMARY_TRUNCATED = false
    var truncated = false // Primary input/structure only; never the alternate budget.
    var selected_video_count: Int { selected.count }
    var selected_source_unmatched: Int { selected.filter { !$0.selection_match }.count }
    var records: [MediaHostRecord] { selected.map(\.safety) }
    var complete: Bool {
        let safe = selected.allSatisfy { $0.safety.url_shape == "CANDIDATE_ONLY" && $0.selected_host != nil }
        let total = hosts.reduce(0) { $0 + $1.selected_work_count }
        let consistent = hosts.allSatisfy { $0.selected_work_count == $0.matched_work_count + $0.unmatched_work_count }
        return !truncated && errors.isEmpty && !selected.isEmpty && selected_source_unmatched == 0 && safe && total == selected.count && consistent
    }
}

enum SelectedHostEvidence {
    static let maxWorks = 50
    static let maxRates = 128
    static let maxURLsPerField = 256
    static let maxNodes = 100_000
    static let maxStringBytes = 4_194_304
    static let alternateBudget = 1000 // Separate statistics quota; primary evidence has no shared quota.
    private struct Source { let path: String; let field: String; let url: String; let winning: Bool }

    // Check shape/size before calling the original Extractor. Never serialize input or errors.
    static func bounded(_ value: Any, depth: Int = 0, nodes: inout Int, bytes: inout Int) -> Bool {
        nodes += 1
        guard depth <= 20 && nodes <= maxNodes else { return false }
        if let text = value as? String { bytes += text.utf8.count; return text.utf8.count <= 16384 && bytes <= maxStringBytes }
        if let list = value as? [Any] {
            guard list.count <= 1024 else { return false }
            return list.allSatisfy { bounded($0,depth:depth + 1,nodes:&nodes,bytes:&bytes) }
        }
        if let object = value as? [String:Any] {
            guard object.count <= 512 else { return false }
            for (key,child) in object {
                bytes += key.utf8.count
                guard bytes <= maxStringBytes, bounded(child,depth:depth + 1,nodes:&nodes,bytes:&bytes) else { return false }
            }
        }
        return true
    }

    private static func sources(_ item: JSONNode) -> [Source]? {
        if let value = item.node("video.bit_rate")?.raw, !(value is [Any]) { return nil }
        let rates = item.nodes("video.bit_rate")
        guard rates.count <= maxRates else { return nil }
        let best = DouyinExtractor.selectBitrate(item) // Original sorting/selection; no replacement selector.
        var result: [Source] = []
        func append(_ node: JSONNode, _ path: String, _ field: String, _ eligible: Bool) -> Bool {
            if let raw = node.node(path)?.raw, !(raw is [Any]) { return false }
            let list = node.nodes(path)
            guard list.count <= maxURLsPerField else { return false }
            for (n,value) in list.enumerated() {
                guard let url = value.raw as? String else { return false }
                result.append(Source(path:field + "[\(n)]",field:field.hasPrefix("video.bit_rate[") ? "video.bit_rate.play_addr.url_list" : field,
                    url:url,winning:eligible && n == list.count - 1 && url == best.url))
            }
            return true
        }
        guard append(item,"video.play_addr.url_list","video.play_addr.url_list",rates.isEmpty) else { return nil }
        for (n,rate) in rates.enumerated() {
            // Tie-aware provenance check against the original selected tuple. Do not claim one unique winning index.
            let eligible = max(rate.int("play_addr.height"),rate.int("play_addr.width")) == max(best.height,best.width) &&
                rate.int("FPS") == best.fps && rate.int("bit_rate") == best.bitrate && rate.int("play_addr.data_size") == best.dataSize
            guard append(rate,"play_addr.url_list","video.bit_rate[\(n)].play_addr.url_list",eligible) else { return nil }
        }
        return result
    }

    // Internal pure association function also permits testing a mismatched Extractor result; no online input switch.
    static func associate(_ item: JSONNode, selected: String?, workRef: String) -> SelectedWorkEvidence? {
        guard let list = sources(item) else { return nil }
        let address = selected ?? ""
        let matches = address.isEmpty ? [] : list.filter { $0.url == address }
        let winners = matches.filter(\.winning)
        let same = !address.isEmpty && address == DouyinExtractor.selectBitrate(item).url && !winners.isEmpty
        let safety = MediaHostAudit.describe(address,id:workRef,alias:workRef,role:"video_playback",field:"selected",selected:same)
        let components = URLComponents(string:address)
        return SelectedWorkEvidence(work_ref:workRef,selected_host:safety.normalized_host,
            selected_source_paths:matches.map(\.path),winning_source_paths:winners.map(\.path),source_match_count:matches.count,
            selection_method:item.nodes("video.bit_rate").isEmpty ? "ORIGINAL_FALLBACK_LAST" : "ORIGINAL_BITRATE_LAST",
            selection_match:same,match_status:same ? "MATCHED" : "UNMATCHED",
            scheme:components?.scheme?.lowercased() == "https" ? "https" : "REJECTED_OR_MISSING",port:components?.port,
            userinfo_present:safety.userinfo_present,safety:safety)
    }

    static func collect(_ items: [JSONNode]) -> MediaHostCollection {
        var output = MediaHostCollection()
        var nodes = 0, bytes = 0
        guard items.count <= maxWorks, items.allSatisfy({ bounded($0.raw,nodes:&nodes,bytes:&bytes) }) else {
            output.truncated = true; output.errors = ["STRUCTURED_INPUT_LIMIT"]; return output
        }
        var identity: [String:String] = [:] // Real IDs and URLs stay in memory only, never hashes or artifact fields.
        var identitySources: [String:[String]] = [:]
        var pending: [(JSONNode,String,String)] = []
        // PHASE ONE: every unique video is processed before any alternate summary.
        for (index,item) in items.enumerated() {
            if item.object == nil { output.errors.append("INVALID_WORK_OBJECT"); continue }
            let work = DouyinExtractor(options:ExtractionOptions(preferOriginalQuality:false)).work(from:item,collectionTime:"")
            if work.kind != .video { output.non_video_resource_counts["non_video_work",default:0] += 1; continue }
            let ref = String(format:"WORK-%03d",index + 1)
            var address = ""
            if work.downloads.count == 1, case .media(let value) = work.downloads[0] { address = value }
            guard !work.id.isEmpty, work.id.count <= 30, work.id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                output.errors.append("INVALID_WORK_ID"); continue
            }
            guard let evidence = associate(item,selected:address,workRef:ref) else {
                output.truncated = true; output.errors.append("VIDEO_SOURCE_STRUCTURE_LIMIT"); continue
            }
            if let prior = identity[work.id] {
                output.duplicate_work_count += 1
                if prior != address || identitySources[work.id] != evidence.selected_source_paths { output.errors.append("CONFLICTING_DUPLICATE_WORK") }
                continue
            }
            identity[work.id] = address
            identitySources[work.id] = evidence.selected_source_paths
            output.selected.append(evidence)
            pending.append((item,address,ref))
            for field in ["video.cover.url_list","video.dynamic_cover.url_list","author.avatar_thumb.url_list","author.avatar_medium.url_list","author.avatar_larger.url_list","music.play_url.url_list"] {
                output.non_video_resource_counts[field,default:0] += item.nodes(field).count
            }
        }
        // Aggregate unique works separately from source-link counts; nil hosts remain visible unmatched buckets.
        var groups: [String:SelectedHostSummary] = [:]
        for evidence in output.selected {
            let key = evidence.selected_host ?? "<UNRESOLVED>"
            var group = groups[key] ?? SelectedHostSummary(host:evidence.selected_host)
            group.selected_work_count += 1
            if evidence.selection_match { group.matched_work_count += 1 } else { group.unmatched_work_count += 1 }
            for path in evidence.selected_source_paths { group.source_field_counts[path,default:0] += 1 }
            groups[key] = group
        }
        output.hosts = groups.keys.sorted().compactMap { groups[$0] }
        // PHASE TWO: capped aggregate statistics only; no URL-level alternate records.
        var alternates: [String:AlternateHostSummary] = [:]
        for (item,address,ref) in pending {
            for source in sources(item) ?? [] where source.url != address {
                guard output.alternate_urls_examined < alternateBudget else { output.ALTERNATE_SUMMARY_TRUNCATED = true; continue }
                output.alternate_urls_examined += 1
                let safety = MediaHostAudit.describe(source.url,id:ref,alias:ref,role:"video_playback",field:source.field,selected:false)
                let key = safety.normalized_host ?? "<UNRESOLVED>"
                var group = alternates[key] ?? AlternateHostSummary(host:safety.normalized_host)
                group.occurrences += 1; group.source_field_counts[source.field,default:0] += 1
                if !group.work_refs.contains(ref) { group.work_refs.append(ref) }
                alternates[key] = group
            }
        }
        output.alternates = alternates.keys.sorted().compactMap { alternates[$0] }
        return output
    }
}
