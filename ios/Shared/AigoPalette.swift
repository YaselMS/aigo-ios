import SwiftUI

extension Color {
    /// 0xRRGGBB sRGB color.
    init(aigoHex hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

/// Aigo colours, shared by the app and the widget extension.
enum AigoPalette {
    static let background = Color(aigoHex: 0x0B0C0E)    // graphite
    static let surface = Color(aigoHex: 0x121417)       // cards, rows
    static let surfaceRaised = Color(aigoHex: 0x191C20) // inputs, chips
    static let line = Color(aigoHex: 0x23262B)          // borders
    static let lineSoft = Color(aigoHex: 0x1A1D21)      // timeline rail, separators
    static let text = Color(aigoHex: 0xE6E7E3)
    static let secondary = Color(aigoHex: 0x9DA1A6)
    static let idle = Color(aigoHex: 0x5E636B)
    static let lime = Color(aigoHex: 0xC6F432)          // alive / working / primary action
    static let coral = Color(aigoHex: 0xFF7A59)         // needs you
    static let ice = Color(aigoHex: 0x8FB8C9)           // done
    static let coralWash = Color(aigoHex: 0x1C0F0B)     // background of a "needs you" card
    static let coralText = Color(aigoHex: 0xFFB29C)
    static let coralCode = Color(aigoHex: 0xFFD3C6)
    static let coralLine = Color(aigoHex: 0x3A2A25)
    static let onAccent = Color(aigoHex: 0x0B0C0E)      // text on lime
    static let onCoral = Color(aigoHex: 0x1A0B06)       // text on coral
    static let coralButtonText = Color(aigoHex: 0xFF9A7E) // text of soft coral buttons
    static let iceText = Color(aigoHex: 0x9CC6D6)       // text of soft ice buttons
    static let iconSquare = Color(aigoHex: 0x1B1E22)    // app icon background
}
