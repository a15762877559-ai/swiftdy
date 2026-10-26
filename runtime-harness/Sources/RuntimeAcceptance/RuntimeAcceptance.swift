import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import CoreMedia
import DouStudioKit

@main
struct RuntimeAcceptance {
    static let upstream = "362dad3d082e9f63c8efd360acc653ba169d40a2"

    @MainActor static func main() async {
        if [["--media-host-audit-self-test"],["--media-host-evidence-self-test"]].contains(Array(CommandLine.arguments.dropFirst())) {
            do {
                let baseline = try await SelfTest.run()
                let audit = try await MediaHostAuditSelfTest.run()
                let priority = try await HostEvidencePrioritySelfTest.run()
                if !baseline || !audit || !priority { exit(1) }
            } catch { print("HOST_AUDIT_OFFLINE_ERROR"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--pagination-self-test") {
            do {
                let original = try await SelfTest.run()
                let pagination = try await PaginationSelfTest.run()
                if !original || !pagination { exit(1) }
            } catch {
                print("PAGINATION_OFFLINE_INFRASTRUCTURE_ERROR")
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            do {
                let passed = try await SelfTest.run()
                print(passed ? "Offline harness checks PASS" : "Offline harness checks FAIL")
                if !passed { exit(1) }
            } catch {
                print("OFFLINE_DIAGNOSTIC_WRITE_OR_INFRASTRUCTURE_FAILURE; details redacted")
                exit(1)
            }
            return
        }
        if ProcessInfo.processInfo.environment["OFFLINE_ONLY"] == "1" {
            print("ONLINE_ENTRY_DISABLED_IN_OFFLINE_MODE")
            exit(64)
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--media-host-audit"] {
            do {
                let passed = try await MediaHostAudit.run(environment: ProcessInfo.processInfo.environment)
                if !passed { exit(2) }
            } catch { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--authenticated-pagination") {
            do {
                let passed = try await AuthenticatedPagination.run(environment: ProcessInfo.processInfo.environment)
                if !passed { exit(2) }
            } catch { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--authenticated-preflight") {
            do {
                let passed = try await AuthenticatedPreflight.run(environment: ProcessInfo.processInfo.environment)
                if !passed { exit(2) }
            } catch { exit(1) } // No credential-bearing exception descriptions.
            return
        }
        do { try await execute() }
        catch {
            // Never stringify an upstream error: descriptions may contain URLs or bodies.
            print("Harness infrastructure failure; no upstream error details emitted.")
            exit(1)
        }
    }

    @MainActor static func execute() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let evidencePath = env["EVIDENCE_DIR"], let mediaPath = env["MEDIA_DIR"] else { exit(1) }
        let evidence = URL(fileURLWithPath: evidencePath, isDirectory: true)
        let media = URL(fileURLWithPath: mediaPath, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var states = [
            "BUILD_BASELINE": "PASS", "PROFILE_URL_RESOLUTION": "NOT_RUN",
            "WORKLIST_FETCH": "NOT_RUN", "MULTI_PAGE_FETCH": "NOT_RUN",
            "PAGINATION_CORRECTNESS": "NOT_RUN", "WORK_ITEM_FIELDS": "NOT_RUN",
            "VIDEO_DOWNLOAD": "NOT_RUN", "MEDIA_INTEGRITY": "NOT_RUN",
            "NO_WATERMARK": "NOT_TESTED", "CURRENT_INTERFACE_COMPATIBILITY": "NOT_RUN",
            "RUST_IMPLEMENTATION": "NOT_STARTED", "UPSTREAM_SOURCE_CHANGED": "NO",
            "VIDEOFLOW_CHANGED": "NO", "ROOTNETSCOPE_CHANGED": "NO"
        ]
        var failures: [[String: String]] = []
        var profile: [String: Any] = [:]
        var download: [String: Any] = ["attempted": false]
        let observer = ObservingTransport()
        var phase = "profile"
        var timelineSucceeded = false
        var phaseFailure: AcceptanceStop?
        do {
            guard env["RUNTIME_CONSENT"] == "true", let input = env["PROFILE_URL"],
                  let url = safeHTTPS(input), url.host == "www.douyin.com",
                  url.query == nil, url.fragment == nil,
                  let link = LinkParser().parse(input), !link.requiresExpansion,
                  case .user(let secUid, let modal) = link.target,
                  modal == nil, url.path == "/user/" + secUid else {
                throw AcceptanceStop(code: "CANONICAL_PUBLIC_PROFILE_AND_CONSENT_REQUIRED", blocked: true)
            }
            states["PROFILE_URL_RESOLUTION"] = "PASS"
            profile = ["status": "PASS", "identifier_sha256": digest(Data(secUid.utf8)),
                       "identifier_length": secUid.count, "network_expansion": false]
            phase = "worklist"
            let configuration = KernelConfiguration(downloadRoot: media.path, storageTargets: [],
                pageSize: 18, maxPages: 3, maxConcurrency: 1, maxRetry: 0,
                timeout: 30, preferOriginalQuality: false)
            // Explicit empty cookie prevents the library from consulting DOUYIN_COOKIE.
            let client = try await DouyinClient(configuration: configuration, cookie: "",
                                                transport: observer, logger: .disabled)
            let endpoints = await client.endpoints
            _ = try await endpoints.accountTimeline(secUid: secUid, tab: .post,
                page: PageRequest(count: 18, maxPages: 3, cursor: 0))
            timelineSucceeded = true
            phase = "download"
            let observation = await observer.snapshot()
            guard let work = observation.candidate, case .media(let address) = work.downloads[0] else {
                throw AcceptanceStop(code: "NO_SINGLE_PUBLIC_VIDEO_WITH_ALLOWED_METADATA", blocked: true)
            }
            try await observer.allowMedia(address)
            download["attempted"] = true
            download["work_id"] = work.id
            let downloader = await client.downloader
            let outcome = try await downloader.download(work: work)
            guard case .downloaded(let paths) = outcome, paths.count == 1 else {
                throw AcceptanceStop(code: "DOWNLOAD_OUTCOME_NOT_ONE_NEW_FILE", blocked: false)
            }
            let file = paths[0]
            guard file.standardizedFileURL.path.hasPrefix(media.standardizedFileURL.path + "/") else {
                throw AcceptanceStop(code: "DOWNLOAD_PATH_OUTSIDE_TEMP", blocked: false)
            }
            let data = try Data(contentsOf: file)
            let after = await observer.snapshot()
            guard data.count == after.mediaBytes, digest(data) == after.mediaHash else {
                throw AcceptanceStop(code: "WRITTEN_FILE_MISMATCH", blocked: false)
            }
            download["bytes"] = data.count
            download["sha256"] = digest(data)
            download["write_matches_response"] = true
            states["VIDEO_DOWNLOAD"] = "PASS"
            states["NO_WATERMARK"] = "NOT_CONFIRMED"
            phase = "decode"
            let asset = AVURLAsset(url: file)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw AcceptanceStop(code: "NO_VIDEO_TRACK", blocked: false) }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            guard reader.canAdd(output) else { throw AcceptanceStop(code: "DECODER_UNAVAILABLE", blocked: false) }
            reader.add(output)
            guard reader.startReading() else { throw AcceptanceStop(code: "DECODE_START_FAILED", blocked: false) }
            var frames = 0
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetImageBuffer(sample) != nil else {
                    throw AcceptanceStop(code: "DECODED_FRAME_MISSING", blocked: false)
                }
                frames += 1
            }
            guard reader.status == .completed, frames > 0 else {
                throw AcceptanceStop(code: "DECODE_INCOMPLETE", blocked: false)
            }
            download["decoded_frames"] = frames
            download["decoder"] = "AVFoundation AVAssetReader full video track to BGRA"
            states["MEDIA_INTEGRITY"] = "PASS"
        } catch {
            let stop = classify(error)
            phaseFailure = stop
            failures.append(["phase": phase, "code": stop.code, "classification": stop.blocked ? "BLOCKED" : "FAIL"])
            if phase == "profile" { states["PROFILE_URL_RESOLUTION"] = stop.blocked ? "BLOCKED" : "FAIL" }
            if phase == "download" { states["VIDEO_DOWNLOAD"] = stop.blocked ? "BLOCKED" : "FAIL" }
            if phase == "decode" { states["MEDIA_INTEGRITY"] = "FAIL" }
        }
        let snapshot = await observer.snapshot()
        if states["PROFILE_URL_RESOLUTION"] == "PASS" {
            let failureStatus = phaseFailure?.blocked == true ? "BLOCKED" : "FAIL"
            states["WORKLIST_FETCH"] = snapshot.pages.contains { $0.hasMore != nil } ? "PASS" : failureStatus
            if timelineSucceeded {
                // A one-page exhausted account does not prove multi-page fetching.
                states["MULTI_PAGE_FETCH"] = snapshot.pages.count >= 2 ? "PASS" : "BLOCKED"
                states["PAGINATION_CORRECTNESS"] = snapshot.pages.count >= 2
                    ? (snapshot.pages.allSatisfy { $0.error == nil && $0.duplicateIDs == 0 } ? "PASS" : "FAIL")
                    : "NOT_VERIFIED"
            } else {
                states["MULTI_PAGE_FETCH"] = failureStatus
                let paginationErrors = ["MISSING_OR_INVALID_PAGINATION", "CURSOR_STALLED_OR_CYCLIC", "EMPTY_PAGE_WITH_MORE", "REQUEST_CURSOR_MISMATCH"]
                states["PAGINATION_CORRECTNESS"] = snapshot.pages.contains { paginationErrors.contains($0.error ?? "") } ? "FAIL" : "NOT_VERIFIED"
                states["VIDEO_DOWNLOAD"] = "BLOCKED"
            }
            if !snapshot.fields.isEmpty {
                states["WORK_ITEM_FIELDS"] = snapshot.fields.allSatisfy(\.complete) ? "PASS"
                    : (snapshot.fields.contains(where: \.complete) ? "PARTIAL" : "FAIL")
            }
            let required = ["WORKLIST_FETCH", "MULTI_PAGE_FETCH", "PAGINATION_CORRECTNESS", "WORK_ITEM_FIELDS", "VIDEO_DOWNLOAD", "MEDIA_INTEGRITY"]
            states["CURRENT_INTERFACE_COMPATIBILITY"] = required.allSatisfy { states[$0] == "PASS" } ? "PASS"
                : (states["WORKLIST_FETCH"] == "PASS" ? "PARTIAL" : "FAIL")
        }
        if !timelineSucceeded && snapshot.pages.isEmpty { download["prerequisite"] = "WORKLIST_NOT_AVAILABLE" }
        download["status"] = states["VIDEO_DOWNLOAD"]
        download["media_integrity"] = states["MEDIA_INTEGRITY"]
        download["no_watermark"] = states["NO_WATERMARK"]
        try writeJSON(profile.merging(["status": states["PROFILE_URL_RESOLUTION"]!]) { _, new in new },
                      to: evidence.appendingPathComponent("profile-resolution.json"))
        try writeJSON(["status": states["WORKLIST_FETCH"]!, "pages_received": snapshot.pages.count,
                       "item_count": snapshot.fields.count, "exchanges": try jsonObject(snapshot.exchanges)],
                      to: evidence.appendingPathComponent("worklist-result.json"))
        try writeJSON(["status": states["MULTI_PAGE_FETCH"]!, "correctness": states["PAGINATION_CORRECTNESS"]!,
                       "limit": 3, "records": try jsonObject(snapshot.pages),
                       "stop_reason": snapshot.pages.last?.hasMore == false ? "SERVER_EXHAUSTED" : (timelineSucceeded ? "THREE_PAGE_CAP" : "ERROR_OR_BLOCK")],
                      to: evidence.appendingPathComponent("pagination-result.json"))
        try writeJSON(["status": states["WORK_ITEM_FIELDS"]!, "records": try jsonObject(snapshot.fields),
                       "values_redacted": "Descriptions and URLs are represented only by presence/validity; IDs remain strings."],
                      to: evidence.appendingPathComponent("field-validation.json"))
        try writeJSON(download, to: evidence.appendingPathComponent("download-validation.json"))
        try writeJSON(["observations": failures], to: evidence.appendingPathComponent("failure-observations.json"))
        try writeJSON(["phase": "REAL_RUNTIME", "upstream_commit": upstream, "statuses": states],
                      to: evidence.appendingPathComponent("final-acceptance.json"))
        print("Runtime evidence saved; inspect final-acceptance.json. No URLs or raw responses logged.")
        if states["CURRENT_INTERFACE_COMPATIBILITY"] != "PASS" { exit(2) }
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    static func classify(_ error: Error) -> AcceptanceStop {
        if let stop = error as? AcceptanceStop { return stop }
        if let upstream = error as? DouStudioError {
            switch upstream {
            case .missingCredentials(_): return AcceptanceStop(code: "UPSTREAM_MISSING_CREDENTIALS", blocked: true)
            case .signatureRejected(_): return AcceptanceStop(code: "UPSTREAM_ACCESS_REJECTED", blocked: true)
            case .rateLimited(_): return AcceptanceStop(code: "UPSTREAM_RATE_LIMITED", blocked: true)
            case .notFound(_): return AcceptanceStop(code: "UPSTREAM_NOT_PUBLIC_OR_NOT_FOUND", blocked: true)
            case .httpStatus(let code, _):
                return AcceptanceStop(code: "UPSTREAM_HTTP_\(code)", blocked: [401,403,404,429].contains(code))
            case .malformedResponse(_): return AcceptanceStop(code: "UPSTREAM_MALFORMED_RESPONSE", blocked: false)
            case .emptyPayload(_): return AcceptanceStop(code: "UPSTREAM_EMPTY_PAYLOAD", blocked: true)
            case .transport(_): return AcceptanceStop(code: "UPSTREAM_TRANSPORT_ERROR", blocked: false)
            case .storage(_): return AcceptanceStop(code: "UPSTREAM_STORAGE_ERROR", blocked: false)
            default: break
            }
        }
        return AcceptanceStop(code: "UPSTREAM_OR_MEDIA_ERROR_REDACTED", blocked: false)
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
