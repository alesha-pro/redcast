import Foundation

extension RaycastHue {
    /// Fork: a tag's colour, FNV-1a over its folded spelling, so `Work` is one colour everywhere.
    static func tag(_ name: String) -> RaycastHue {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in TagList.key(name).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return agentChoices[Int(hash % UInt64(agentChoices.count))]
    }
}
