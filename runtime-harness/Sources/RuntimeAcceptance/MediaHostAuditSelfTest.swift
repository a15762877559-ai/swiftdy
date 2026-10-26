import Foundation
import DouStudioKit

@MainActor enum MediaHostAuditSelfTest {
    static func record(_ url: String) -> MediaHostRecord {
        MediaHostAudit.describe(url,id:"FIXTURE",alias:"WORK-001",role:"video_playback",field:"video.play_addr.url_list[0]",selected:true)
    }
    static func run() async throws -> Bool {
        var results: [OfflineCaseResult] = []
        func check(_ id: String, _ name: String, _ condition: Bool) {
            results.append(OfflineCaseResult(id:id,name:name,function:"MediaHostAudit",status:condition ? "PASS" : "FAIL",
                errorCategory:condition ? "NONE" : "FIXTURE_MISMATCH",expected:"fixed_condition_true",actual:condition ? "true" : "false"))
            print("\(id) \(condition ? "PASS" : "FAIL")")
        }
        let a = record("https://MEDIA.FIXTURE-CDN.COM/private-path?redacted_probe=secret")
        check("HOST-001","Normalize exact host without URL",a.normalized_host == "media.fixture-cdn.com" && a.url_shape == "CANDIDATE_ONLY" && !a.approved)
        check("HOST-002","HTTP rejected",record("http://media.fixture-cdn.com/a").reason == "HTTPS_REQUIRED")
        check("HOST-003","Userinfo rejected",record("https://synthetic:secret@media.fixture-cdn.com/a").reason == "USERINFO_REJECTED")
        check("HOST-004","Unexpected port rejected",record("https://media.fixture-cdn.com:8443/a").reason == "PORT_REJECTED")
        check("HOST-005","HTTPS port accepted as candidate only",record("https://media.fixture-cdn.com:443/a").url_shape == "CANDIDATE_ONLY")
        check("HOST-006","IPv4 private and loopback rejected",["127.0.0.1","10.1.2.3","192.168.1.2","169.254.169.254","2130706433","0x7f000001"].allSatisfy { record("https://" + $0 + "/a").url_shape == "REJECTED" })
        check("HOST-007","IPv6 rejected",record("https://[::1]/a").ip_or_numeric_host)
        check("HOST-008","Local names rejected",["localhost","host.local","host.internal","host.lan"].allSatisfy { record("https://" + $0 + "/a").url_shape == "REJECTED" })
        check("HOST-009","Ambiguous names rejected",["host..com","-bad.com","bad-.com","cdn.com.","xn--demo.com"].allSatisfy { record("https://" + $0 + "/a").url_shape == "REJECTED" })
        check("HOST-010","No automatic suffix trust",!record("https://douyin.com.attacker.com/a").approved)
        check("HOST-011","Fragment rejected",record("https://media.fixture-cdn.com/a#fragment").url_shape == "REJECTED")
        let encoded = String(data:try JSONEncoder().encode(a),encoding:.utf8) ?? ""
        check("HOST-012","Serialization omits full URL and query",!encoded.contains("redacted_probe") && !encoded.contains("private-path") && !encoded.contains("https://"))
        func item(_ video: [String:Any], images: [[String:Any]] = []) -> JSONNode {
            JSONNode(["aweme_id":"9876543210123456789","desc":"fixture","create_time":1,"video":video,"images":images,
                "author":["avatar_thumb":["url_list":["https://avatar.fixture-cdn.com/a"]]]])
        }
        let fallback = MediaHostAudit.collect([item(["play_addr":["url_list":["https://first.fixture-cdn.com/a","https://last.fixture-cdn.com/a"]],
            "cover":["url_list":["https://cover.fixture-cdn.com/a"]]])])
        check("HOST-013","Original fallback selects LAST URL",fallback.records.filter(\.selected_by_original_extractor).map(\.normalized_host) == ["last.fixture-cdn.com"])
        check("HOST-014","Cover and avatar distinguished",Set(fallback.records.map(\.role)) == Set(["video_playback","cover_image","avatar_image"]))
        let rates: [[String:Any]] = [
            ["FPS":30,"bit_rate":1,"play_addr":["width":1080,"height":1920,"data_size":100,"url_list":["https://best.fixture-cdn.com/a"]]],
            ["FPS":60,"bit_rate":999,"play_addr":["width":360,"height":640,"data_size":1000,"url_list":["https://small.fixture-cdn.com/a"]]]]
        let bitrate = MediaHostAudit.collect([item(["bit_rate":rates,"play_addr":["url_list":["https://fallback.fixture-cdn.com/a"]]])])
        check("HOST-015","Original bitrate selection and exact provenance",bitrate.records.filter(\.selected_by_original_extractor).first?.source_field == "video.bit_rate[0].play_addr.url_list[0]" && bitrate.selected_source_unmatched == 0)
        let album = MediaHostAudit.collect([item(["play_addr":["url_list":["https://album.fixture-cdn.com/a"]]],images:[["url_list":["https://image.fixture-cdn.com/a"]]])])
        check("HOST-016","Image work never video candidate",album.selected_video_count == 0 && !album.records.contains { $0.role == "video_playback" })
        let capped = MediaHostAudit.collect([item(["play_addr":["url_list":Array(repeating:"https://media.fixture-cdn.com/a",count:21)]])])
        check("HOST-017","Truncation explicit",capped.truncated)
        check("HOST-018","No DNS or redirect assurance claimed",a.dns_target_check == "NOT_VERIFIED_NO_DNS_LOOKUP" && a.redirect_risk == "UNKNOWN_NOT_REQUESTED_REDIRECTS_FORBIDDEN")
        let empty = MediaHostAudit.collect([])
        check("HOST-019","Empty data cannot identify a host",empty.records.isEmpty && empty.selected_video_count == 0)
        check("HOST-020","Run-local aliases never real work IDs",fallback.records.allSatisfy { $0.work_alias == "WORK-001" && !$0.approved })
        let passed = results.allSatisfy { $0.status == "PASS" }
        guard let path = ProcessInfo.processInfo.environment["HOST_EVIDENCE_DIR"] else { throw AuthPreflightError.scope }
        try MediaHostAudit.write(results,"host-selftest-results.json",URL(fileURLWithPath:path))
        print("HOST_OFFLINE_SUMMARY total=\(results.count) passed=\(results.filter { $0.status == "PASS" }.count)")
        return passed
    }
}
