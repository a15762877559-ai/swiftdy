import Foundation
import DouStudioKit
import SafeDownloadSupport

@MainActor enum SingleDownloadSelfTest {
    static let cases = ["full200","full206","unknownLength","partial206","oneByte206","redirectCDN","html","json",
        "corruptMdat","brokenBox","empty","disconnect","budgetHeader","budgetChunked","ignoreRange","tlsProxy"]
    static func policy() throws -> Bool {
        guard let path = ProcessInfo.processInfo.environment["DOWNLOAD_EVIDENCE_DIR"] else { return false }
        let good = "https://www.douyin.com/private-fixture?fixture_token=DO_NOT_SERIALIZE"
        let outside = "https://v5-dy-ov-experiment.zjcdn.com/private-fixture"
        let items = [HostEvidencePrioritySelfTest.video(1,urls:[outside]),HostEvidencePrioritySelfTest.video(2,urls:[outside,good]),HostEvidencePrioritySelfTest.video(3,urls:[good])]
        let selection = try SingleVideoRealDownload.select(items)
        let checks = ["deterministic_first_www":selection.2 == 1,"original_last_url":selection.1.absoluteString == good,
            "ordinary_video":selection.0.kind == .video && selection.0.downloads.count == 1,
            "no_alternate_cdn":(try? SingleVideoRealDownload.select([items[0]])) == nil,
            "empty_rejected":(try? SingleVideoRealDownload.select([])) == nil]
        try MediaHostAudit.write(checks,"download-policy-tests.json",URL(fileURLWithPath:path))
        return checks.values.allSatisfy { $0 }
    }
    static func generate() async throws {
        guard ProcessInfo.processInfo.environment["OFFLINE_ONLY"] == "1",let path = ProcessInfo.processInfo.environment["DOWNLOAD_FIXTURE_ROOT"] else { throw AuthPreflightError.scope }
        try await SingleVideoDownloadBridge.generateFixture(URL(fileURLWithPath:path).appendingPathComponent("valid.mp4"))
    }
    static func fixture(_ args: [String]) async throws -> Bool {
        guard args.count == 2,cases.contains(args[0]),let port = Int(args[1]),(1024...65535).contains(port),
              ProcessInfo.processInfo.environment["OFFLINE_ONLY"] == "1",let parent = ProcessInfo.processInfo.environment["DOWNLOAD_MEDIA_ROOT"],
              let evidence = ProcessInfo.processInfo.environment["PROBE_CASE_DIR"] else { return false }
        let id = args[0], folder = URL(fileURLWithPath:evidence)
        let item = HostEvidencePrioritySelfTest.video(10,urls:["https://www.douyin.com/private-fixture?fixture_token=DO_NOT_SERIALIZE"])
        let work = try SingleVideoRealDownload.select([item]).0
        var tunnel: PinnedProbeTunnel?
        let url: URL, proxyPort: Int?
        if id == "tlsProxy" {
            let value = try await PinnedProbeTunnel.fixture(port:UInt16(port)); tunnel = value; proxyPort = value.port
            url = URL(string:"https://v5-dy-ov-experiment.zjcdn.com/private-fixture")!
        } else { proxyPort = nil; url = URL(string:"http://127.0.0.1:\(port)/\(id)")! }
        let receipt = await SingleVideoDownloadBridge.run(work:work,targetURL:url,proxyPort:proxyPort,mediaParent:URL(fileURLWithPath:parent),fixture:id != "tlsProxy")
        try receipt.json.write(to:folder.appendingPathComponent("transfer-results.json"))
        if let tunnel {
            let end = await tunnel.finish(); try MediaHostAudit.write(end,"tunnel-result.json",folder)
            guard end.outbound_connections == 1,end.connect_authority_matched,!end.credential_headers_seen else { return false }
        }
        let expectedSuccess = ["full200","full206","unknownLength","ignoreRange"].contains(id)
        return receipt.success == expectedSuccess && receipt.cleanup && receipt.mediaRequests == 1
    }
}
