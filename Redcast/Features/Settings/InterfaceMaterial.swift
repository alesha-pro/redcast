import Foundation

/// What Redcast's own surfaces are made of; an unset key reads as `.glass`.
enum InterfaceMaterial: String, CaseIterable, Identifiable, Sendable {
    case glass
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: String(localized: "Glass")
        case .solid: String(localized: "Solid")
        }
    }
}
