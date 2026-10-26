import Foundation
import AVFoundation
import CoreVideo
import CryptoKit

struct MediaProof: Codable {
    var file_bytes: Int64 = 0
    var sha256: String = ""
    var repeated_sha256_matches = false
    var mp4_container = false
    var video_track = false
    var decoded_frames = 0
    var decoder_completed = false
}

enum IntegrationMedia {
    // Parse bounded top-level box headers without buffering the media body.
    static func verifyBoxes(_ file: URL, size: Int64) throws {
        let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        var position: UInt64 = 0; var seen: Set<String> = []; var boxes = 0
        while position < UInt64(size) {
            guard boxes < 10000 else { throw IntegrationError.container }; boxes += 1
            try handle.seek(toOffset:position)
            guard let head = try handle.read(upToCount:8), head.count == 8 else { throw IntegrationError.container }
            var length = head.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(data:head.suffix(4),encoding:.ascii) ?? ""
            var header: UInt64 = 8
            if length == 1 {
                guard let extended = try handle.read(upToCount:8), extended.count == 8 else { throw IntegrationError.container }
                length = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; header = 16
            } else if length == 0 { length = UInt64(size) - position }
            guard length >= header, length <= UInt64(size) - position else { throw IntegrationError.container }
            if ["ftyp","moov","mdat"].contains(type), length > header { seen.insert(type) }
            position += length
        }
        guard seen == ["ftyp","moov","mdat"] else { throw IntegrationError.container }
    }
    static func validate(_ file: URL, accepted: Int64) async throws -> MediaProof {
        var proof = MediaProof()
        let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= SafeStreamingTransport.MAX_MEDIA_BYTES, Int64(size) == accepted else { throw IntegrationError.file }
        proof.file_bytes = Int64(size)
        proof.sha256 = try ControlledTests.hash(file)
        proof.repeated_sha256_matches = proof.sha256 == (try ControlledTests.hash(file))
        guard proof.repeated_sha256_matches else { throw IntegrationError.file }
        try verifyBoxes(file,size:Int64(size)); proof.mp4_container = true
        let asset = AVURLAsset(url:file)
        let tracks = try await asset.loadTracks(withMediaType:.video)
        guard let track = tracks.first else { throw IntegrationError.track }; proof.video_track = true
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw IntegrationError.decode }; reader.add(output)
        guard reader.startReading() else { throw IntegrationError.decode }
        defer { reader.cancelReading() }
        let deadline = Date().addingTimeInterval(15)
        while let sample = output.copyNextSampleBuffer() {
            guard Date() < deadline, proof.decoded_frames < 1000, CMSampleBufferDataIsReady(sample),
                  let image = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(image) > 0,
                  CVPixelBufferGetHeight(image) > 0 else { throw IntegrationError.decode }
            proof.decoded_frames += 1
        }
        proof.decoder_completed = reader.status == .completed
        guard proof.decoded_frames > 0, proof.decoder_completed else { throw IntegrationError.decode }
        return proof
    }
    static func generate(_ file: URL) async throws {
        guard !FileManager.default.fileExists(atPath:file.path) else { throw IntegrationError.fixture }
        let writer = try AVAssetWriter(outputURL:file,fileType:.mp4)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
        guard writer.canAdd(input) else { throw IntegrationError.fixture }; writer.add(input)
        guard writer.startWriting() else { throw IntegrationError.fixture }
        writer.startSession(atSourceTime:.zero)
        let deadline = Date().addingTimeInterval(15)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline else { throw IntegrationError.fixture }
                try await Task.sleep(for:.milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess, let buffer else { throw IntegrationError.fixture }
            CVPixelBufferLockBaseAddress(buffer,[])
            if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address,Int32(frame * 7),CVPixelBufferGetBytesPerRow(buffer)*64) }
            CVPixelBufferUnlockBaseAddress(buffer,[])
            guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else { throw IntegrationError.fixture }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw IntegrationError.fixture }
    }
    @MainActor static func generateMain() async {
        guard let directory = ProcessInfo.processInfo.environment["INT_FIXTURE_ROOT"] else { exit(2) }
        do {
            let file = URL(fileURLWithPath:directory).appendingPathComponent("valid.mp4")
            try await generate(file)
            let size = Int64(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
            let proof = try await validate(file,accepted:size)
            guard proof.decoded_frames == 30 else { throw IntegrationError.fixture }
            print("FIXTURE_GENERATION=PASS frames=30")
            exit(0)
        } catch { print("FIXTURE_GENERATION=FAIL"); exit(1) }
    }
}
