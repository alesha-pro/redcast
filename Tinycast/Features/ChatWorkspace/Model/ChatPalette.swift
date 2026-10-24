import Foundation

/// Fork: the ink a coloured section header or label takes, deep enough to read as text.
enum ChatPalette {
    /// The tile's tone a fifth darker on the light surface, which brings every hue past 4.5:1.
    static func lightInk(_ hue: RaycastHue) -> UInt32 { scaled(hue.tile, by: 0.8) }

    /// Raycast Dark's own value reads on the dark surface as it is.
    static func darkInk(_ hue: RaycastHue) -> UInt32 { hue.dark }

    static func scaled(_ hex: UInt32, by factor: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            UInt32((Double((hex >> shift) & 0xFF) * factor).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// WCAG's contrast ratio between two opaque sRGB colours.
    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func linear(_ shift: UInt32) -> Double {
                let value = Double((hex >> shift) & 0xFF) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
        }
        let (high, low) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (high + 0.05) / (low + 0.05)
    }
}
