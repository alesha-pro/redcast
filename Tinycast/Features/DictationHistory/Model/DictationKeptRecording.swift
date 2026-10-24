import Foundation

/// A failed dictation's recording kept to retry: named by its entry, bounded, read back as samples.
struct DictationKeptRecording: Equatable, Sendable {
    /// A week of failures to get back to, ten five-minute recordings at most.
    static let maxCount = 20
    static let maxAge: TimeInterval = 7 * 86_400
    static let maxBytes = 100_000_000

    let id: UUID
    /// Whole seconds, as the name stores it.
    let date: Date
    let bytes: Int

    init(id: UUID, date: Date, bytes: Int) {
        self.id = id
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.bytes = bytes
    }

    /// The date's seconds, then the entry's id, so a trim never opens a file to date it.
    var fileName: String { "\(Int64(date.timeIntervalSince1970))-\(id.uuidString).wav" }

    /// nil for any name this build does not write, which a trim then leaves alone.
    init?(fileName: String, bytes: Int) {
        guard fileName.hasSuffix(".wav"), let dash = fileName.firstIndex(of: "-") else { return nil }
        let seconds = fileName[..<dash]
        let id = fileName[fileName.index(after: dash)...].dropLast(4)
        guard !seconds.isEmpty, seconds.allSatisfy(\.isASCII), let value = Int64(seconds),
            let uuid = UUID(uuidString: String(id))
        else { return nil }
        self.init(id: uuid, date: Date(timeIntervalSince1970: TimeInterval(value)), bytes: bytes)
    }

    /// The oldest date kept at `now`: a week back, or the history's own span when that is shorter.
    static func cutoff(now: Date, history: Date?) -> Date {
        max(now.addingTimeInterval(-maxAge), history ?? .distantPast)
    }

    /// What a trim removes: all before `cutoff`, then, newest first, all past the count or bytes.
    static func expired(_ recordings: [Self], cutoff: Date) -> Set<UUID> {
        let newestFirst = recordings.sorted {
            $0.date != $1.date ? $0.date > $1.date : $0.id.uuidString > $1.id.uuidString
        }
        var expired = Set<UUID>()
        var count = 0
        var bytes = 0
        var full = false
        for recording in newestFirst {
            full = full || recording.date < cutoff || count == maxCount || bytes + recording.bytes > maxBytes
            if full {
                expired.insert(recording.id)
            } else {
                count += 1
                bytes += recording.bytes
            }
        }
        return expired
    }

    /// The mono PCM16 samples of a WAV at `sampleRate`, scaled to ±1; nil for anything else.
    static func samples(fromWAV data: Data, sampleRate: Int) -> [Float]? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float]? in
            func word(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            func half(_ offset: Int) -> UInt16 {
                UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            }
            guard raw.count >= 12, word(0) == fourCC("RIFF"), word(8) == fourCC("WAVE") else { return nil }
            var offset = 12
            var format = false
            while offset + 8 <= raw.count {
                let size = Int(word(offset + 4))
                let body = offset + 8
                if word(offset) == fourCC("fmt "), size >= 16, body + 16 <= raw.count {
                    format = half(body) == 1 && half(body + 2) == 1 && word(body + 4) == UInt32(sampleRate)
                        && half(body + 14) == 16
                    guard format else { return nil }
                } else if word(offset) == fourCC("data") {
                    guard format else { return nil }
                    let count = min(size, raw.count - body) / 2
                    return (0..<count).map { Float(Int16(bitPattern: half(body + $0 * 2))) / 32_767 }
                }
                offset = body + size + (size & 1)
            }
            return nil
        }
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
