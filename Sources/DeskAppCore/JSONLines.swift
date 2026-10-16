import Foundation

/// Streams a JSONL file line by line, handing over only lines that contain every marker
/// (a cheap byte search before any JSON decoding).
enum JSONLines {
    static func forEach(_ url: URL, containing markers: [String] = [], _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let needles = markers.map { Data($0.utf8) }
        let newline = UInt8(ascii: "\n")
        var pending = Data()
        var reachedEnd = false
        while !reachedEnd {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else {
                    reachedEnd = true
                    // A last line without a trailing newline is still complete at EOF.
                    if !pending.isEmpty, matches(pending, needles) { body(pending) }
                    return
                }
                pending.append(chunk)
                guard let lastNewline = pending.lastIndex(of: newline) else { return }
                for line in pending[..<lastNewline].split(separator: newline) where matches(line, needles) {
                    body(Data(line))
                }
                pending = Data(pending[(lastNewline + 1)...])
            }
        }
    }

    private static func matches(_ line: Data, _ needles: [Data]) -> Bool {
        needles.allSatisfy { line.range(of: $0) != nil }
    }

    /// Files under `root` with the given suffix, modified at or after `cutoff`.
    static func files(under root: URL, suffix: String, modifiedSince cutoff: Date) -> [(url: URL, modified: Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= cutoff {
                result.append((url, modified))
            }
        }
        return result.sorted { $0.1 > $1.1 }
    }
}
