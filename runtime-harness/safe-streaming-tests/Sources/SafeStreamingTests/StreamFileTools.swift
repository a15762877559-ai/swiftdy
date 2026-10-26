import Foundation
import CryptoKit

// Shared by the existing controlled executable and the runtime support module; streams 64 KiB at a time.
enum StreamFileTools {
    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount:65536), !data.isEmpty { hash.update(data:data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func files(_ root: URL) -> [URL] {
        guard let entries = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { return [] }
        return entries.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true }
    }
}
