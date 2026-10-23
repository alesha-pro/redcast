import Foundation

/// What a DOCX's or ODT's ZIP says it unpacks to, by its central directory, before AppKit opens it.
nonisolated enum DocumentArchive {
    /// XML is what the importer builds text from, at several times its size in memory.
    static let maxMarkupBytes: UInt64 = 32 * 1_048_576
    /// Pictures and the rest are held as they unpack.
    static let maxTotalBytes: UInt64 = 256 * 1_048_576
    /// A real document has a few dozen entries; past this the directory alone is a burden.
    static let maxDirectoryBytes = 4 * 1_048_576
    /// The end record and the longest comment a ZIP may put after it.
    static let tailBytes: UInt64 = 22 + 65_535

    struct Sizes: Equatable, Sendable {
        var markup: UInt64 = 0
        var total: UInt64 = 0
        var entries = 0
    }

    enum Verdict: Equatable, Sendable {
        case readable(Sizes)
        /// It would unpack past a limit, or is too large to say: ZIP64, or a directory past its limit.
        case tooLarge
        /// No central directory where a ZIP keeps one.
        case notArchive
    }

    /// `tail` is the file's last `tailBytes`, or all of it; `read` gives the directory's bytes.
    static func verdict(tail: Data, fileSize: UInt64, read: (_ offset: UInt64, _ size: Int) -> Data?) -> Verdict {
        let bytes = [UInt8](tail)
        guard bytes.count >= 22 else { return .notArchive }
        var index = bytes.count - 22
        while index >= 0, little32(bytes, index) != 0x0605_4B50 { index -= 1 }
        guard index >= 0 else { return .notArchive }
        let size = UInt64(little32(bytes, index + 12))
        let offset = UInt64(little32(bytes, index + 16))
        // ZIP64 marks these fields as full; no document needs it, so it is not read.
        guard little16(bytes, index + 10) != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else {
            return .tooLarge
        }
        guard size <= UInt64(maxDirectoryBytes) else { return .tooLarge }
        guard offset + size <= fileSize, let directory = read(offset, Int(size)), directory.count == Int(size)
        else { return .notArchive }
        return verdict(ofDirectory: directory)
    }

    /// Each entry's declared size against the limits; the end record's count is not trusted.
    static func verdict(ofDirectory data: Data) -> Verdict {
        let bytes = [UInt8](data)
        var sizes = Sizes()
        var index = 0
        while index + 46 <= bytes.count, little32(bytes, index) == 0x0201_4B50 {
            let inflated = UInt64(little32(bytes, index + 24))
            let nameLength = Int(little16(bytes, index + 28))
            guard inflated != 0xFFFF_FFFF, index + 46 + nameLength <= bytes.count else { return .tooLarge }
            let named = bytes[(index + 46)..<(index + 46 + nameLength)]
            let name = String(bytes: named, encoding: .utf8)?.lowercased() ?? ""
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") { sizes.markup += inflated }
            sizes.total += inflated
            sizes.entries += 1
            guard sizes.markup <= maxMarkupBytes, sizes.total <= maxTotalBytes else { return .tooLarge }
            index += 46 + nameLength + Int(little16(bytes, index + 30)) + Int(little16(bytes, index + 32))
        }
        return sizes.entries > 0 ? .readable(sizes) : .notArchive
    }

    private static func little16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func little32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(little16(bytes, at)) | UInt32(little16(bytes, at + 2)) << 16
    }
}
