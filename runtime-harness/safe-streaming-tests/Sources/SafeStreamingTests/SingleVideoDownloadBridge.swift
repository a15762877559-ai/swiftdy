import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import CoreMedia
import DouStudioKit

public struct SingleVideoBridgeReceipt: Sendable {
    public let json: Data // Diagnostic JSON only; never contains file contents, a path, URL or original work identifier.
    public let success: Bool
    public let cleanup: Bool
    public let mediaRequests: Int
}
private struct RealMediaProof: Codable, Sendable {
    var file_bytes: Int64 = 0
    var sha256 = ""
    var repeated_sha256_matches = false
    var container_complete = false
    var video_tracks = 0
    var duration_seconds = 0.0
    var width = 0.0, height = 0.0, frame_rate = 0.0
    var codec = "NOT_RUN"
    var decoded_frames = 0
    var first_frame_seconds: Double?
    var last_frame_seconds: Double?
    var start_decoded = false, middle_decoded = false, end_decoded = false
    var full_decode_completed = false
    var corruption_detected = false
    var corruption_assessment = "NOT_RUN"
    var decode_method = "FULL_SEQUENTIAL_VIDEO_TRACK_TO_PIXEL_BUFFERS"
    let audio_decode = "NOT_RUN"
    let NO_WATERMARK = "NOT_VERIFIED"
}
private struct RealTransferEvidence: Codable, Sendable {
    var success = false
    var category = "NOT_RUN"
    var downloader_completed = false
    var APPLICATION_BYTE_BUDGET = "NOT_RUN"
    var MEDIA_FILE_INTEGRITY = "NOT_RUN"
    var MEDIA_DECODE = "NOT_RUN"
    var FULL_DECODE = "NOT_RUN"
    var TEMP_FILE_CLEANUP = "NOT_RUN"
    var metrics: StreamMetrics?
    var media = RealMediaProof()
    var written_bytes: Int64 = 0
    var partial_files_before_cleanup = 0
    var completion_wait_succeeded = false
    var declared_length_matches: Bool?
    var completeness_method = "NOT_RUN"
    let STRICT_NETWORK_RECEIVE_LIMIT = "NOT_PROVEN"
    let PRODUCTION_ALLOWLIST = "EMPTY"
}

// One implementation of the original Downloader flow, compiled from the SAME SafeStreamingTransport
// source into the support target and the existing controlled-test executable. No second downloader.
@MainActor public enum SingleVideoDownloadBridge {
    private static let target = "v5-dy-ov-experiment.zjcdn.com"
    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    private static func inspect(_ file: URL, accepted: Int64, evidence: inout RealTransferEvidence) async throws {
        let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, Int64(size) == accepted, Int64(size) <= SafeStreamingTransport.MAX_MEDIA_BYTES else { throw IntegrationError.file }
        evidence.media.file_bytes = Int64(size)
        evidence.media.sha256 = try StreamFileTools.hash(file)
        evidence.media.repeated_sha256_matches = evidence.media.sha256 == (try StreamFileTools.hash(file))
        guard evidence.media.repeated_sha256_matches else { throw IntegrationError.file }
        try IntegrationMedia.verifyBoxes(file,size:Int64(size)); evidence.media.container_complete = true
        let asset = AVURLAsset(url:file)
        let tracks = try await asset.loadTracks(withMediaType:.video)
        evidence.media.video_tracks = tracks.count
        guard tracks.count == 1, let track = tracks.first else { throw IntegrationError.track }
        let duration = try await asset.load(.duration).seconds
        let range = try await track.load(.timeRange)
        let length = range.duration.seconds, start = range.start.seconds
        let sizeValue = try await track.load(.naturalSize), fps = Double(try await track.load(.nominalFrameRate))
        let descriptions = try await track.load(.formatDescriptions)
        guard duration.isFinite, duration > 0, duration <= 7200, length.isFinite, length > 0, start.isFinite,
              abs(sizeValue.width) > 0, abs(sizeValue.width) <= 8192, abs(sizeValue.height) > 0, abs(sizeValue.height) <= 8192,
              fps.isFinite, fps > 0, fps <= 240, let description = descriptions.first else { throw IntegrationError.track }
        evidence.media.duration_seconds = rounded(duration)
        evidence.media.width = Double(abs(sizeValue.width)); evidence.media.height = Double(abs(sizeValue.height))
        evidence.media.frame_rate = rounded(fps)
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [UInt8((code >> 24) & 255),UInt8((code >> 16) & 255),UInt8((code >> 8) & 255),UInt8(code & 255)]
        evidence.media.codec = bytes.allSatisfy { $0 >= 32 && $0 <= 126 } ? (String(bytes:bytes,encoding:.ascii) ?? "OTHER") : "OTHER"
        let reader = try AVAssetReader(asset:asset)
        evidence.MEDIA_DECODE = "FAIL"; evidence.FULL_DECODE = "FAIL"
        evidence.media.corruption_assessment = "NOT_DETERMINED"
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw IntegrationError.decode }; reader.add(output)
        guard reader.startReading() else {
            evidence.media.corruption_detected = reader.status == .failed
            evidence.media.corruption_assessment = reader.status == .failed ? "DETECTED_BY_DECODER" : "NOT_DETERMINED"
            throw IntegrationError.decode
        }
        defer { reader.cancelReading() }
        evidence.MEDIA_DECODE = "FAIL"; evidence.FULL_DECODE = "FAIL"
        evidence.media.corruption_assessment = "NOT_DETERMINED"
        let deadline = Date().addingTimeInterval(180)
        let tolerance = min(2.0,max(0.25,2.0 / fps))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard Date() < deadline, evidence.media.decoded_frames < 250_000, CMSampleBufferDataIsReady(sample),
                  let image = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(image) > 0,
                  CVPixelBufferGetHeight(image) > 0 else { throw IntegrationError.decode }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite else { throw IntegrationError.decode }
            if evidence.media.first_frame_seconds == nil { evidence.media.first_frame_seconds = rounded(time) }
            evidence.media.last_frame_seconds = rounded(time)
            evidence.media.start_decoded = evidence.media.start_decoded || abs(time - start) <= tolerance
            evidence.media.middle_decoded = evidence.media.middle_decoded || abs(time - (start + length / 2)) <= tolerance
            evidence.media.end_decoded = evidence.media.end_decoded || time >= start + length - tolerance
            evidence.media.decoded_frames += 1
        }
        evidence.media.full_decode_completed = reader.status == .completed
        evidence.media.corruption_detected = reader.status == .failed
        evidence.media.corruption_assessment = reader.status == .failed ? "DETECTED_BY_DECODER" : (reader.status == .completed ? "NO_DECODER_ERRORS_OBSERVED" : "NOT_DETERMINED")
        guard evidence.media.decoded_frames > 0, evidence.media.full_decode_completed,
              evidence.media.start_decoded, evidence.media.middle_decoded, evidence.media.end_decoded else { throw IntegrationError.decode }
        evidence.MEDIA_FILE_INTEGRITY = "PASS"; evidence.MEDIA_DECODE = "PASS"; evidence.FULL_DECODE = "PASS"
    }
    public static func generateFixture(_ file: URL) async throws { try await IntegrationMedia.generate(file) }
    public static func run(work: DouyinWork, targetURL: URL, proxyPort: Int?, mediaParent: URL, fixture: Bool = false) async -> SingleVideoBridgeReceipt {
        var report = RealTransferEvidence()
        let parent = mediaParent.standardizedFileURL
        let root = parent.appendingPathComponent("video-" + UUID().uuidString,isDirectory:true)
        var transport: SafeStreamingTransport?
        do {
            guard root.deletingLastPathComponent() == parent, !FileManager.default.fileExists(atPath:root.path),
                  work.kind == .video, work.downloads.count == 1 else { throw IntegrationError.kind }
            if !fixture {
                guard targetURL.scheme == "https",targetURL.host?.lowercased() == target,targetURL.user == nil,targetURL.password == nil,
                      targetURL.fragment == nil,targetURL.port == nil || targetURL.port == 443,
                      let proxyPort,(1024...65535).contains(proxyPort) else { throw IntegrationError.host }
            }
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
            let streaming: SafeStreamingTransport
            if fixture { streaming = try SafeStreamingTransport(loopbackURL:targetURL,timeout:15) }
            else { streaming = SafeStreamingTransport(extractedMediaURL:targetURL,verifiedMediaHosts:[target],timeout:30,pinnedProxyPort:proxyPort) }
            transport = streaming
            // Adapter copies the real extracted model, replaces ONLY its destination with this run's validated Location,
            // and removes identifying naming metadata so the original ID/title never reaches filesystem names.
            var adapted = work
            adapted.id = "RUN-VIDEO-001"; adapted.desc = ""; adapted.nickname = "acceptance"; adapted.uniqueId = ""; adapted.signature = ""
            adapted.downloads = [.media(url:targetURL.absoluteString)]
            let downloader = Downloader(transport:streaming,session:SessionStore(cookie:"",maxRetry:0),layout:DownloadLayout(root:root),logger:.disabled)
            let outcome: DownloadOutcome
            do {
                outcome = try await withTaskCancellationHandler {
                    try await downloader.download(work:adapted,progress:{ _ in })
                } onCancel: { streaming.cancel() }
            } catch { streaming.cancel(); _ = await streaming.awaitCompletion(); throw error }
            report.completion_wait_succeeded = await streaming.awaitCompletion()
            guard report.completion_wait_succeeded, case .downloaded(let files) = outcome, files.count == 1,
                  files[0].standardizedFileURL.path.hasPrefix(root.path + "/") else { throw IntegrationError.outcome }
            report.downloader_completed = true
            let metrics = streaming.snapshot()
            guard metrics.buffered_send_calls == 0, metrics.stream_calls == 1, metrics.completion_callbacks == 1,
                  metrics.completion_received, metrics.accepted_bytes <= SafeStreamingTransport.MAX_MEDIA_BYTES else { throw IntegrationError.outcome }
            if let declared = metrics.declared_bytes {
                report.declared_length_matches = declared == metrics.accepted_bytes
                guard report.declared_length_matches == true else { throw IntegrationError.file }
                report.completeness_method = metrics.http_status == 206 ? "FULL_RESOURCE_206_LENGTH_AND_CONTAINER_FULL_DECODE" : "DECLARED_LENGTH_CONTAINER_AND_FULL_DECODE"
            } else { report.completeness_method = "CLEAN_HTTP_EOF_COMPLETE_CONTAINER_AND_FULL_DECODE" }
            report.APPLICATION_BYTE_BUDGET = "PASS"; report.MEDIA_FILE_INTEGRITY = "FAIL"
            try await inspect(files[0],accepted:metrics.accepted_bytes,evidence:&report)
            report.success = true; report.category = "PASS"
        } catch {
            report.category = (error as? SafeStreamError)?.rawValue ?? (error as? IntegrationError)?.rawValue ?? (error is CancellationError ? "CALLER_CANCELLED" : "SANITIZED_DOWNLOAD_OR_DECODE_ERROR")
            if let transport {
                transport.cancel()
                if transport.snapshot().stream_calls > 0 { report.completion_wait_succeeded = await transport.awaitCompletion() }
            }
        }
        if let transport { report.metrics = transport.snapshot() }
        let files = StreamFileTools.files(root)
        report.written_bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
        report.partial_files_before_cleanup = files.filter { $0.pathExtension == "part" }.count
        if report.written_bytes > SafeStreamingTransport.MAX_MEDIA_BYTES || (report.metrics?.accepted_bytes ?? 0) > SafeStreamingTransport.MAX_MEDIA_BYTES {
            report.APPLICATION_BYTE_BUDGET = "FAIL"; report.success = false
        } else if report.metrics != nil { report.APPLICATION_BYTE_BUDGET = "PASS" }
        do {
            guard root.deletingLastPathComponent() == parent, root.lastPathComponent.hasPrefix("video-") else { throw IntegrationError.cleanup }
            if FileManager.default.fileExists(atPath:root.path) { try FileManager.default.removeItem(at:root) }
            report.TEMP_FILE_CLEANUP = FileManager.default.fileExists(atPath:root.path) ? "FAIL" : "PASS"
        } catch { report.TEMP_FILE_CLEANUP = "FAIL" }
        report.success = report.success && report.TEMP_FILE_CLEANUP == "PASS"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = (try? encoder.encode(report)) ?? Data("{\"success\":false,\"category\":\"EVIDENCE_ENCODING_FAILED\"}".utf8)
        return SingleVideoBridgeReceipt(json:data,success:report.success,cleanup:report.TEMP_FILE_CLEANUP == "PASS",mediaRequests:report.metrics?.media_requests_started ?? 0)
    }
}
