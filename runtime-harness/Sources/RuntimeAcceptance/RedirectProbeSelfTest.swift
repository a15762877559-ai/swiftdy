import Foundation
import DouStudioKit

enum RedirectFixtureCases {
    static let all = ["next206","nextRedirect","unapproved","httpTarget","userinfo","portTarget","privateDNS","mixedDNS",
        "missingLocation","relativeTarget","schemeRelative","javascript","target200","target403","target429",
        "targetHTML","targetBadRange","www403","www429","sf11Present","sf11Absent","sf11Only","noSamples","www403sf11","nextRedirectsf11"]
}
struct FixtureRedirectExecutor: RedirectProbeExecutor {
    let caseID: String, port: Int
    func execute(_ role: RedirectProbeRole, url: URL) async -> RedirectProbeExchange {
        if role == .target {
            let addresses = caseID == "privateDNS" ? ["127.0.0.1"] : (caseID == "mixedDNS" ? ["8.8.8.8","10.0.0.1"] : ["8.8.8.8"])
            do { _ = try RedirectNetworkSafety.vet(host:RedirectProbePolicy.targetHost,addresses:addresses) }
            catch {
                var o = LiveProbeObservation(host:RedirectProbePolicy.targetHost); o.result = "NON_PUBLIC_OR_UNSUPPORTED_ADDRESS"
                return RedirectProbeExchange(evidence:RedirectHopEvidence(role:role,observation:o,network_target_check:"BLOCKED_SYNTHETIC_DNS"),location:nil)
            }
        }
        let host = role == .www ? RedirectProbePolicy.www : (role == .sf11 ? RedirectProbePolicy.sf11 : RedirectProbePolicy.targetHost)
        let task = LiveProbeTask(host:host,captureLocation:role == .www)
        // Synthetic-only adapter. Caller cannot supply arbitrary destinations. The live executor never enters this path.
        let local = URL(string:"http://127.0.0.1:\(port)/\(caseID)/\(role.rawValue)")!
        let o = await task.run(local,fixture:true)
        return RedirectProbeExchange(evidence:RedirectHopEvidence(role:role,observation:o,
            network_target_check:role == .target ? "SYNTHETIC_PUBLIC_DNS_CHECK_LOOPBACK_ADAPTER" : "SYNTHETIC_LOOPBACK_ONLY"),location:task.takeLocation())
    }
}

@MainActor enum RedirectProbeSelfTest {
    static func policy() throws -> Bool {
        guard let path = ProcessInfo.processInfo.environment["REDIRECT_EVIDENCE_DIR"] else { return false }
        let target = "https://\(RedirectProbePolicy.targetHost)/private-fixture?fixture_token=DO_NOT_SERIALIZE"
        var tests: [String:Bool] = [:]
        tests["exact_target"] = RedirectProbePolicy.targetAllowed(URL(string:target)!)
        for (key,value) in ["http":"http://\(RedirectProbePolicy.targetHost)/a","userinfo":"https://u:p@\(RedirectProbePolicy.targetHost)/a",
            "port":"https://\(RedirectProbePolicy.targetHost):444/a","suffix":"https://\(RedirectProbePolicy.targetHost).evil.com/a",
            "scheme_relative":"//\(RedirectProbePolicy.targetHost)/a","relative":"/a","javascript":"javascript:alert(1)","fragment":target + "#x"] {
            tests[key + "_rejected"] = RedirectProbePolicy.absoluteLocation(value).map { !RedirectProbePolicy.targetAllowed($0) } ?? true
        }
        for value in ["0.0.0.0","10.0.0.1","100.64.0.1","127.0.0.1","169.254.169.254","172.16.0.1","192.168.0.1",
            "192.0.2.1","198.18.0.1","198.51.100.1","203.0.113.1","224.0.0.1","255.255.255.255","::1","fc00::1","fe80::1",
            "::ffff:127.0.0.1","2001:db8::1","2002:7f00:1::1","2001::1","3ffe::1","3fff::1"] {
            tests["private_or_special_\(tests.count)_rejected"] = !RedirectNetworkSafety.publicAddress(value)
        }
        tests["public_ipv4"] = RedirectNetworkSafety.publicAddress("8.8.8.8")
        tests["public_ipv6"] = RedirectNetworkSafety.publicAddress("2606:4700:4700::1111")
        tests["mixed_dns_rejected"] = (try? RedirectNetworkSafety.vet(host:RedirectProbePolicy.targetHost,addresses:["8.8.8.8","10.0.0.1"])) == nil
        tests["empty_dns_rejected"] = (try? RedirectNetworkSafety.vet(host:RedirectProbePolicy.targetHost,addresses:[])) == nil
        var budget = RedirectRequestBudget()
        tests["target_before_www_rejected"] = !budget.reserve(.target)
        tests["three_slots"] = budget.reserve(.www) && budget.reserve(.target) && budget.reserve(.sf11)
        tests["no_fourth_or_repeated_slot"] = !budget.reserve(.www) && !budget.reserve(.target) && !budget.reserve(.sf11)
        let samples = try MediaRedirectProbe.select([HostEvidencePrioritySelfTest.video(1,urls:[target,"https://www.douyin.com/original-last?fixture_token=DO_NOT_SERIALIZE"])])
        tests["original_extractor_last"] = samples.www?.path == "/original-last"
        tests["sf11_missing_explicit"] = samples.sf11 == nil && samples.coverage.sf11_sample_status == "NO_ELIGIBLE_SAMPLE"
        let sf = try MediaRedirectProbe.select([HostEvidencePrioritySelfTest.video(2,urls:["https://sf11-cdn-tos.douyinstatic.com/private-fixture"])])
        tests["sf11_selected_once"] = sf.sf11 != nil && sf.www == nil && sf.coverage.sf11_selected_source_count == 1
        try MediaHostAudit.write(tests,"redirect-policy-tests.json",URL(fileURLWithPath:path))
        return tests.values.allSatisfy { $0 }
    }
    static func fixture(_ args: [String]) async throws -> Bool {
        guard args.count == 2, RedirectFixtureCases.all.contains(args[0]), let port = Int(args[1]), (1024...65535).contains(port),
              let path = ProcessInfo.processInfo.environment["PROBE_CASE_DIR"],ProcessInfo.processInfo.environment["OFFLINE_ONLY"] == "1" else { return false }
        let id = args[0]
        var items: [JSONNode] = []
        if !["sf11Only","noSamples"].contains(id) { items.append(HostEvidencePrioritySelfTest.video(1,urls:["https://www.douyin.com/private-fixture?fixture_token=DO_NOT_SERIALIZE"])) }
        if ["sf11Present","sf11Only","www403sf11","nextRedirectsf11"].contains(id) { items.append(HostEvidencePrioritySelfTest.video(2,urls:["https://sf11-cdn-tos.douyinstatic.com/private-fixture?fixture_token=DO_NOT_SERIALIZE"])) }
        if id == "noSamples" { items.append(HostEvidencePrioritySelfTest.video(3,urls:["https://outside.fixture-cdn.com/private-fixture"])) }
        let output = await MediaRedirectProbe.probe(try MediaRedirectProbe.select(items),executor:FixtureRedirectExecutor(caseID:id,port:port))
        try MediaRedirectProbe.publish(output,folder:URL(fileURLWithPath:path))
        return output.MEDIA_REQUEST_COUNT <= 3 && output.hops.allSatisfy {
            $0.observation.request_count <= 1 && $0.observation.accepted_bytes <= 1 && !$0.observation.authentication_headers_sent &&
            (!$0.observation.cancel_requested || $0.observation.cancel_completed)
        }
    }
    static func tunnel(_ args: [String], tls: Bool) async throws -> Bool {
        guard args.count == 1, let port = UInt16(args[0]),port >= 1024,
              let path = ProcessInfo.processInfo.environment["PROBE_CASE_DIR"],ProcessInfo.processInfo.environment["OFFLINE_ONLY"] == "1" else { return false }
        let folder = URL(fileURLWithPath:path), tunnel = try await PinnedProbeTunnel.fixture(port:port)
        if tls {
            let o = await LiveProbeTask(host:RedirectProbePolicy.targetHost,scope:.redirectTarget,proxyPort:tunnel.port)
                .run(URL(string:"https://\(RedirectProbePolicy.targetHost)/private-fixture")!)
            let end = await tunnel.finish()
            try MediaHostAudit.write(o,"tls-observation.json",folder)
            try MediaHostAudit.write(end,"tunnel-result.json",folder)
            return o.accepted_bytes == 0 && ["TLS_ERROR","NETWORK_OR_TIMEOUT_ERROR"].contains(o.result) && end.outbound_connections == 1 && end.connect_authority_matched
        }
        try MediaHostAudit.write(["port":tunnel.port],"tunnel-ready.json",folder)
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath:folder.appendingPathComponent("tunnel-finish").path) { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        let end = await tunnel.finish()
        try MediaHostAudit.write(end,"tunnel-result.json",folder)
        return end.outbound_connections <= 1 && !end.credential_headers_seen && end.stopped
    }
}
