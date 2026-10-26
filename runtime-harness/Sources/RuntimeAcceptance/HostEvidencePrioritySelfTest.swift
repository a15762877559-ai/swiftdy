import Foundation
import DouStudioKit

@MainActor enum HostEvidencePrioritySelfTest {
    static let selectedURL = "https://selected.fixture-cdn.com/hidden-media-path?fixture_token=DO_NOT_SERIALIZE"
    static func video(_ id: Int, urls: [String]? = nil, rates: [[String:Any]]? = nil) -> JSONNode {
        var value: [String:Any] = ["play_addr":["url_list":urls ?? [selectedURL]],
            "cover":["url_list":["https://cover.fixture-cdn.com/hidden-cover"]]]
        if let rates { value["bit_rate"] = rates }
        return JSONNode(["aweme_id":String(1_000_000_000_000_000_000 + id),"desc":"PRIVATE_TITLE_MARKER","create_time":1,
            "video":value,"author":["avatar_thumb":["url_list":["https://avatar.fixture-cdn.com/hidden-avatar"]]],
            "music":["play_url":["url_list":["https://audio.fixture-cdn.com/hidden-audio"]]]])
    }
    static func rate(_ width: Int, _ url: String, fps: Int = 30, bitrate: Int = 10, size: Int = 100) -> [String:Any] {
        ["FPS":fps,"bit_rate":bitrate,"play_addr":["width":width,"height":width,"data_size":size,
            "url_list":["https://first.fixture-cdn.com/not-selected",url]]]
    }
    static func run() async throws -> Bool {
        var results: [OfflineCaseResult] = []
        func check(_ id: String,_ name: String,_ condition: Bool) {
            results.append(OfflineCaseResult(id:id,name:name,function:"SelectedHostEvidence",status:condition ? "PASS" : "FAIL",
                errorCategory:condition ? "NONE" : "FIXTURE_MISMATCH",expected:"fixed_condition_true",actual:condition ? "true" : "false"))
            print("\(id) \(condition ? "PASS" : "FAIL")")
        }
        let many = (0..<21).map { i in video(i,urls:(0..<60).map { "https://alternate.fixture-cdn.com/backup/\(i)/\($0)?fixture_token=DO_NOT_SERIALIZE" } + [selectedURL]) }
        let large = SelectedHostEvidence.collect(many)
        check("PRI-001","21 selected records survive 1260 alternate URLs",large.selected.count == 21 && large.complete)
        check("PRI-002","Every selected source uses actual last address",large.selected.allSatisfy { $0.selection_match && $0.winning_source_paths == ["video.play_addr.url_list[60]"] })
        check("PRI-003","Separate alternate budget capped at old limit",large.alternate_urls_examined == 1000 && large.ALTERNATE_SUMMARY_TRUNCATED && !large.truncated)
        check("PRI-004","Primary host aggregation equals works",large.hosts.count == 1 && large.hosts[0].selected_work_count == 21 && large.hosts[0].matched_work_count == 21 && large.hosts[0].unmatched_work_count == 0)
        let bitrate = SelectedHostEvidence.collect([video(1,rates:[rate(1080,selectedURL),rate(360,"https://low.fixture-cdn.com/a",fps:60,bitrate:1000)])])
        check("PRI-005","Original tuple chooses resolution before FPS and bitrate",bitrate.complete && bitrate.selected[0].winning_source_paths == ["video.bit_rate[0].play_addr.url_list[1]"])
        check("PRI-006","Missing bit_rate fallback uses last URL",large.selected.allSatisfy { $0.selection_method == "ORIGINAL_FALLBACK_LAST" })
        let emptyRates = SelectedHostEvidence.collect([video(1,urls:["https://first.fixture-cdn.com/a",selectedURL],rates:[])])
        check("PRI-007","Empty bit_rate fallback",emptyRates.complete && emptyRates.selected[0].winning_source_paths == ["video.play_addr.url_list[1]"])
        let shared = SelectedHostEvidence.collect([video(1,urls:[selectedURL,selectedURL],rates:[rate(1080,selectedURL),rate(1080,selectedURL)])])
        check("PRI-008","All exact source matches retained without claiming uniqueness",shared.complete && shared.selected[0].source_match_count == 4 && shared.selected[0].winning_source_paths.count == 2)
        check("PRI-009","Four source associations are one work",shared.hosts[0].selected_work_count == 1 && shared.hosts[0].source_field_counts.values.reduce(0,+) == 4)
        let unmatched = SelectedHostEvidence.associate(video(1),selected:"https://unmatched.fixture-cdn.com/a",workRef:"WORK-001")
        check("PRI-010","Exact mismatch never guessed by host",unmatched?.selection_match == false && unmatched?.source_match_count == 0 && unmatched?.match_status == "UNMATCHED")
        let absent = SelectedHostEvidence.collect([video(1,urls:[])])
        check("PRI-011","Missing address remains explicit unmatched work",absent.selected.count == 1 && absent.selected_source_unmatched == 1 && !absent.complete && absent.hosts[0].unmatched_work_count == 1)
        var albumObject = video(2).object!; albumObject["images"] = [["url_list":["https://album.fixture-cdn.com/a"]]]
        let mixed = SelectedHostEvidence.collect([video(1),JSONNode(albumObject)])
        check("PRI-012","Cover avatar audio album cannot enter video summary",mixed.complete && mixed.selected.count == 1 && mixed.hosts.map(\.host) == ["selected.fixture-cdn.com"] && mixed.non_video_resource_counts["non_video_work"] == 1 && mixed.non_video_resource_counts["video.cover.url_list"] == 1)
        let duplicate = SelectedHostEvidence.collect([video(1),video(1),video(2)])
        check("PRI-013","Duplicate work ID counted once without exporting ID",duplicate.complete && duplicate.duplicate_work_count == 1 && duplicate.selected.count == 2 && duplicate.hosts[0].selected_work_count == 2)
        let conflict = SelectedHostEvidence.collect([video(1),video(1,urls:["https://changed.fixture-cdn.com/a"])])
        check("PRI-014","Conflicting duplicate fails closed",!conflict.complete && conflict.errors.contains("CONFLICTING_DUPLICATE_WORK"))
        let encoded = String(data:try JSONEncoder().encode(large),encoding:.utf8) ?? ""
        check("PRI-015","No raw address credentials title or real ID in evidence",["https:","hidden-media-path","fixture_token","DO_NOT_SERIALIZE","PRIVATE_TITLE_MARKER","1000000000000000000","Cookie:","Authorization:"].allSatisfy { !encoded.contains($0) })
        let tooMany = SelectedHostEvidence.collect((0..<51).map { video($0) })
        check("PRI-016","Work limit fails closed before sampling",tooMany.truncated && !tooMany.complete && tooMany.selected.isEmpty)
        let structure = SelectedHostEvidence.collect([video(1,rates:Array(repeating:rate(1,selectedURL),count:129))])
        check("PRI-017","Bitrate structure limit fails closed",structure.truncated && !structure.complete)
        let urlLimit = SelectedHostEvidence.collect([video(1,urls:Array(repeating:selectedURL,count:257))])
        check("PRI-018","URL field structure limit fails closed",urlLimit.truncated && !urlLimit.complete)
        var deep: Any = "fixture"; for _ in 0..<25 { deep = [deep] }; var object = video(1).object!; object["extra"] = deep
        check("PRI-019","Nested input limit fails closed",!SelectedHostEvidence.collect([JSONNode(object)]).complete)
        check("PRI-020","No automatic approval or wildcard output",large.records.allSatisfy { !$0.approved } && large.hosts.allSatisfy { $0.security_review_status == "BLOCKED_INDEPENDENT_REVIEW_REQUIRED" } && !encoded.contains("*."))
        let exactBudget = SelectedHostEvidence.collect((0..<20).map { video($0,urls:Array(repeating:"https://alternate.fixture-cdn.com/a",count:50) + [selectedURL]) })
        check("PRI-021","Exact alternate quota is not truncated",exactBudget.complete && exactBudget.alternate_urls_examined == 1000 && !exactBudget.ALTERNATE_SUMMARY_TRUNCATED)
        let unsafe = SelectedHostEvidence.collect([video(1,urls:["http://selected.fixture-cdn.com/a"])])
        check("PRI-022","Unsafe selected URL cannot be complete",unsafe.selected.count == 1 && !unsafe.complete && unsafe.selected[0].scheme == "REJECTED_OR_MISSING")
        // Exercise FPS, bitrate and data-size tie breaks through the original public selector.
        for (offset,rates) in [
            [rate(1080,"https://low.fixture-cdn.com/a",fps:24),rate(1080,selectedURL,fps:30)],
            [rate(1080,"https://low.fixture-cdn.com/a",bitrate:1),rate(1080,selectedURL,bitrate:10)],
            [rate(1080,"https://low.fixture-cdn.com/a",size:1),rate(1080,selectedURL,size:100)]].enumerated() {
            let r = SelectedHostEvidence.collect([video(1,rates:rates)])
            check(String(format:"PRI-%03d",23 + offset),"Original tuple tie-break verification",r.complete && r.selected[0].winning_source_paths == ["video.bit_rate[1].play_addr.url_list[1]"])
        }
        let passed = results.allSatisfy { $0.status == "PASS" }
        guard let path = ProcessInfo.processInfo.environment["HOST_EVIDENCE_DIR"] else { throw AuthPreflightError.scope }
        let folder = URL(fileURLWithPath:path)
        try MediaHostAudit.write(results,"priority-selftest-results.json",folder)
        try MediaHostAudit.write(large.selected,"selected-work-evidence.json",folder)
        try MediaHostAudit.write(large.hosts,"selected-host-summary.json",folder)
        try MediaHostAudit.write(large.alternates,"alternate-host-summary.json",folder)
        try MediaHostAudit.write(["fixture":"SYNTHETIC_ONLY","selection_match":large.complete ? "PASS" : "FAIL","source_unmatched":String(large.selected_source_unmatched)],"source-association-results.json",folder)
        try MediaHostAudit.write(["fixture":"SYNTHETIC_ONLY","selected_records":String(large.selected.count),"alternate_urls_examined":String(large.alternate_urls_examined),"ALTERNATE_SUMMARY_TRUNCATED":String(large.ALTERNATE_SUMMARY_TRUNCATED),"primary_complete":String(large.complete)],"quota-integrity-results.json",folder)
        try MediaHostAudit.write(["fixture":"SYNTHETIC_ONLY","serialization_check":results.first { $0.id == "PRI-015" }!.status,"approved_hosts":"0"],"security-redaction-results.json",folder)
        print("PRIORITY_OFFLINE_SUMMARY total=\(results.count) passed=\(results.filter { $0.status == "PASS" }.count)")
        return passed
    }
}
