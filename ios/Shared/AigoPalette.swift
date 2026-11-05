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

/// Aigo visual identity, shared by the app and the widget extension.
enum AigoPalette {
    static let background = Color(aigoHex: 0x0F1012)  // graphite
    static let surface = Color(aigoHex: 0x17191C)
    static let surfaceRaised = Color(aigoHex: 0x202327)
    static let line = Color(aigoHex: 0x2C3035)
    static let text = Color(aigoHex: 0xECEDEA)
    static let secondary = Color(aigoHex: 0xA4A8AD)
    static let lime = Color(aigoHex: 0xC6F432)   // alive / working / primary action
    static let coral = Color(aigoHex: 0xFF7A59)  // needs you
    static let ice = Color(aigoHex: 0x8FB8C9)    // done
}
