import Foundation
import DouStudioKit

@MainActor enum LiveProbeSelfTest {
    static let cases = ["range206","ignore200","redirect301","redirect302","redirect307","redirect308",
        "html","json","forbidden403","limited429","badRange","tooMany","empty","challenge","second","relativeRedirect","invalidRedirect","encoded","disconnect"]
    static func policy() throws -> Bool {
        let host = "sf11-cdn-tos.douyinstatic.com"
        let chosen = "https://\(host)/hidden-media-path?fixture_token=DO_NOT_SERIALIZE"
        let other = "https://www.douyin.com/hidden-media-path?fixture_token=DO_NOT_SERIALIZE"
        let items = [HostEvidencePrioritySelfTest.video(1,urls:[other,chosen]),
            HostEvidencePrioritySelfTest.video(2,urls:[chosen]),HostEvidencePrioritySelfTest.video(3,urls:[other])]
        let selected = try LiveProbePolicy.select(items)
        var checks: [String:Bool] = [
            "original_last_address":selected.first?.1.absoluteString == chosen,
            "per_host_one":selected.count == 2 && Set(selected.map(\.0)).count == 2,
            "exact_hosts":LiveProbePolicy.allowed(chosen) && LiveProbePolicy.allowed(other),
            "http_rejected":!LiveProbePolicy.allowed("http://\(host)/a"),
            "suffix_rejected":!LiveProbePolicy.allowed("https://\(host).evil.com/a"),
            "backup_host_rejected":!LiveProbePolicy.allowed("https://v26-web.douyinvod.com/a"),
            "userinfo_rejected":!LiveProbePolicy.allowed("https://u:p@\(host)/a"),
            "port_rejected":!LiveProbePolicy.allowed("https://\(host):444/a"),
            "fragment_rejected":!LiveProbePolicy.allowed(chosen + "#x"),
            "empty_rejected":(try? LiveProbePolicy.select([])) == nil
        ]
        let rateItem = HostEvidencePrioritySelfTest.video(4,urls:[other],rates:[HostEvidencePrioritySelfTest.rate(1080,chosen),HostEvidencePrioritySelfTest.rate(360,other)])
        checks["original_bitrate"] = try LiveProbePolicy.select([rateItem]).first?.1.absoluteString == chosen
        // An allowed backup is never substituted for an original selected URL outside scope.
        checks["no_backup_substitution"] = (try? LiveProbePolicy.select([HostEvidencePrioritySelfTest.video(5,urls:[chosen,"https://v26-web.douyinvod.com/a"])])) == nil
        guard let path = ProcessInfo.processInfo.environment["PROBE_EVIDENCE_DIR"] else { return false }
        try MediaHostAudit.write(checks,"policy-tests.json",URL(fileURLWithPath:path))
        return checks.values.allSatisfy { $0 }
    }
    static func fixture(_ args: [String]) async throws -> Bool {
        guard args.count == 2, cases.contains(args[0]), let port = Int(args[1]), (1024...65535).contains(port),
              let path = ProcessInfo.processInfo.environment["PROBE_CASE_DIR"],
              ProcessInfo.processInfo.environment["OFFLINE_ONLY"] == "1" else { return false }
        let id = args[0]
        let url = URL(string:"http://127.0.0.1:\(port)/\(id)")!
        // Exercise original Extractor on synthetic loopback data as well as actual production host policy above.
        let item = HostEvidencePrioritySelfTest.video(10,urls:["http://127.0.0.1:\(port)/not-selected",url.absoluteString])
        let work = DouyinExtractor(options:ExtractionOptions(preferOriginalQuality:false)).work(from:item,collectionTime:"")
        guard work.kind == .video, work.downloads.count == 1, case .media(let value) = work.downloads[0], value == url.absoluteString else { return false }
        let probe = LiveProbeTask(host:"LOOPBACK_FIXTURE")
        let result = await probe.run(URL(string:value)!,fixture:true)
        let folder = URL(fileURLWithPath:path)
        try MediaHostAudit.write(result,"observation.json",folder)
        if id == "second" {
            let second = await probe.run(url,fixture:true)
            try MediaHostAudit.write(second,"second.json",folder)
            guard second.result == "SINGLE_REQUEST_LIMIT", second.request_count == 0 else { return false }
        }
        return result.request_count == 1 && result.accepted_bytes <= 1 && result.completion_callbacks == 1 && (!result.cancel_requested || result.cancel_completed)
    }
}
