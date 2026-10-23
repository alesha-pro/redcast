import Foundation

/// Fork: Raycast's API colours, the hue a glyph, a tile or an agent takes.
enum RaycastHue: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, purple, magenta
    /// Raycast's own grey tile, for scripts and Tinycast's housekeeping commands.
    case gray

    var id: String { rawValue }

    /// A swatch's tooltip and VoiceOver name.
    var title: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .magenta: String(localized: "Magenta")
        case .gray: String(localized: "Gray")
        }
    }

    /// Raycast Dark's value for `Color.<hue>`: a glyph or text on the dark surface.
    var dark: UInt32 {
        switch self {
        case .red: 0xFF6363
        case .orange: 0xFF9217
        case .yellow: 0xFFC531
        case .green: 0x59D499
        case .blue: 0x56C2FF
        case .purple: 0xA485FF
        case .magenta: 0xCF2F98
        case .gray: 0x999999
        }
    }

    /// Raycast Light's value for `Color.<hue>`, exactly, so an extension matches Raycast.
    var light: UInt32 {
        switch self {
        case .red: 0xB12424
        case .orange: 0xC75D07
        case .yellow: 0xF8A300
        case .green: 0x006B4F
        case .blue: 0x138AF2
        case .purple: 0x6A3DEC
        case .magenta: 0x9A1B6E
        case .gray: 0x666666
        }
    }

    /// A tile under a white glyph, one value in both appearances: Raycast's command-icon tones.
    var tile: UInt32 {
        switch self {
        case .red: 0xF2453D
        case .orange: 0xF27A0C
        case .yellow: 0xE89F00
        case .green: 0x1FA463
        case .blue: 0x138AF2
        case .purple: 0x7D55F0
        case .magenta: 0xCF2F98
        case .gray: 0x7A7F8A
        }
    }

    /// What an agent may wear; grey is kept for Tinycast's own plumbing.
    static let agentChoices: [RaycastHue] = [.red, .orange, .yellow, .green, .blue, .purple, .magenta]

    /// An agent with no colour of its own: FNV-1a over its id, so it never changes between launches.
    static func stable(for id: UUID) -> RaycastHue {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return agentChoices[Int(hash % UInt64(agentChoices.count))]
    }

    /// A stored name from any build: one this build doesn't know reads as the derived colour.
    static func agent(named name: String?, id: UUID) -> RaycastHue {
        guard let hue = name.flatMap(RaycastHue.init(rawValue:)), agentChoices.contains(hue) else {
            return stable(for: id)
        }
        return hue
    }
}
