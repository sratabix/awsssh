import SwiftUI

enum ForwardColor {
    struct Preset {
        let name: String
        let hex: String
    }

    static let presets: [Preset] = [
        Preset(name: "Red", hex: "#FF453A"),
        Preset(name: "Orange", hex: "#FF9F0A"),
        Preset(name: "Yellow", hex: "#FFD60A"),
        Preset(name: "Green", hex: "#30D158"),
        Preset(name: "Teal", hex: "#40C8E0"),
        Preset(name: "Blue", hex: "#0A84FF"),
        Preset(name: "Purple", hex: "#BF5AF2"),
        Preset(name: "Grey", hex: "#98989D"),
    ]

    private static let hexDigits = Set("0123456789ABCDEF")

    static func normalise(_ raw: String) -> String {
        var body = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.count == 3 || body.count == 6, body.allSatisfy(hexDigits.contains) else {
            return ""
        }
        if body.count == 3 { body = body.map { "\($0)\($0)" }.joined() }
        return "#" + body
    }

    static func color(_ raw: String) -> Color? {
        let hex = normalise(raw)
        guard !hex.isEmpty, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func name(_ raw: String) -> String? {
        let hex = normalise(raw)
        return presets.first { $0.hex == hex }?.name
    }
}

extension Forward {
    var tint: Color? { ForwardColor.color(color) }
}
