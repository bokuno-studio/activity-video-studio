import Foundation
import CoreGraphics

/// A text overlay to be displayed at a specific time range on the video.
struct TextOverlay: Identifiable, Codable {
    let id: UUID
    var text: String
    var startTime: TimeInterval      // seconds from video start
    var duration: TimeInterval = 15   // how long to display
    var fontSize: CGFloat = 48
    var position: Position = .center {
        didSet {
            let point = Self.defaultRelativePoint(for: position)
            relativeX = point.x
            relativeY = point.y
        }
    }
    var relativeX: CGFloat = 0.5
    var relativeY: CGFloat = 0.5
    var fontFamily: String = "Helvetica"
    var fontWeight: FontWeight = .bold
    var color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    var backgroundColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.3)
    var strokeColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    var strokeWidth: CGFloat = 0
    var shadowColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.75)
    var shadowBlur: CGFloat = 0
    var shadowOffsetX: CGFloat = 0
    var shadowOffsetY: CGFloat = 0
    var fadeInDuration: TimeInterval = 0
    var fadeOutDuration: TimeInterval = 0.5

    enum Position: String, CaseIterable, Codable {
        case topCenter = "上中央"
        case center = "中央"
        case bottomCenter = "下中央"
    }

    enum FontWeight: String, CaseIterable, Codable, Identifiable {
        case regular
        case medium
        case semibold
        case bold
        case heavy

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .regular: return "Regular"
            case .medium: return "Medium"
            case .semibold: return "Semibold"
            case .bold: return "Bold"
            case .heavy: return "Heavy"
            }
        }
    }

    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval = 15,
        fontSize: CGFloat = 48,
        position: Position = .center,
        relativeX: CGFloat? = nil,
        relativeY: CGFloat? = nil,
        fontFamily: String = "Helvetica",
        fontWeight: FontWeight = .bold,
        color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        backgroundColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.3),
        strokeColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        strokeWidth: CGFloat = 0,
        shadowColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.75),
        shadowBlur: CGFloat = 0,
        shadowOffsetX: CGFloat = 0,
        shadowOffsetY: CGFloat = 0,
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0.5
    ) {
        let defaultPoint = Self.defaultRelativePoint(for: position)
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.fontSize = fontSize
        self.position = position
        self.relativeX = relativeX ?? defaultPoint.x
        self.relativeY = relativeY ?? defaultPoint.y
        self.fontFamily = fontFamily
        self.fontWeight = fontWeight
        self.color = color
        self.backgroundColor = backgroundColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.shadowColor = shadowColor
        self.shadowBlur = shadowBlur
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, startTime, duration, fontSize, position, relativeX, relativeY
        case fontFamily, fontWeight, color, backgroundColor
        case strokeColor, strokeWidth
        case shadowColor, shadowBlur, shadowOffsetX, shadowOffsetY
        case fadeInDuration, fadeOutDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fontSize = try container.decode(CGFloat.self, forKey: .fontSize)
        position = try container.decodeIfPresent(Position.self, forKey: .position) ?? .center
        let defaultPoint = Self.defaultRelativePoint(for: position)
        relativeX = try container.decodeIfPresent(CGFloat.self, forKey: .relativeX) ?? defaultPoint.x
        relativeY = try container.decodeIfPresent(CGFloat.self, forKey: .relativeY) ?? defaultPoint.y
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? "Helvetica"
        fontWeight = try container.decodeIfPresent(FontWeight.self, forKey: .fontWeight) ?? .bold
        color = try container.decode(RGBAColor.self, forKey: .color).cgColor
        backgroundColor = try container.decode(RGBAColor.self, forKey: .backgroundColor).cgColor
        strokeColor = try container.decodeIfPresent(RGBAColor.self, forKey: .strokeColor)?.cgColor ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        strokeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .strokeWidth) ?? 0
        shadowColor = try container.decodeIfPresent(RGBAColor.self, forKey: .shadowColor)?.cgColor ?? CGColor(red: 0, green: 0, blue: 0, alpha: 0.75)
        shadowBlur = try container.decodeIfPresent(CGFloat.self, forKey: .shadowBlur) ?? 0
        shadowOffsetX = try container.decodeIfPresent(CGFloat.self, forKey: .shadowOffsetX) ?? 0
        shadowOffsetY = try container.decodeIfPresent(CGFloat.self, forKey: .shadowOffsetY) ?? 0
        fadeInDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeInDuration) ?? 0
        fadeOutDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeOutDuration) ?? 0.5
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(duration, forKey: .duration)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(position, forKey: .position)
        try container.encode(relativeX, forKey: .relativeX)
        try container.encode(relativeY, forKey: .relativeY)
        try container.encode(fontFamily, forKey: .fontFamily)
        try container.encode(fontWeight, forKey: .fontWeight)
        try container.encode(RGBAColor(color), forKey: .color)
        try container.encode(RGBAColor(backgroundColor), forKey: .backgroundColor)
        try container.encode(RGBAColor(strokeColor), forKey: .strokeColor)
        try container.encode(strokeWidth, forKey: .strokeWidth)
        try container.encode(RGBAColor(shadowColor), forKey: .shadowColor)
        try container.encode(shadowBlur, forKey: .shadowBlur)
        try container.encode(shadowOffsetX, forKey: .shadowOffsetX)
        try container.encode(shadowOffsetY, forKey: .shadowOffsetY)
        try container.encode(fadeInDuration, forKey: .fadeInDuration)
        try container.encode(fadeOutDuration, forKey: .fadeOutDuration)
    }

    static func defaultRelativePoint(for position: Position) -> CGPoint {
        switch position {
        case .topCenter:
            return CGPoint(x: 0.5, y: 0.15)
        case .center:
            return CGPoint(x: 0.5, y: 0.5)
        case .bottomCenter:
            return CGPoint(x: 0.5, y: 0.85)
        }
    }

    mutating func applyPresetPosition(_ position: Position) {
        self.position = position
        let point = Self.defaultRelativePoint(for: position)
        relativeX = point.x
        relativeY = point.y
    }

    mutating func clampRelativePosition() {
        relativeX = min(max(relativeX, 0), 1)
        relativeY = min(max(relativeY, 0), 1)
    }

    /// Opacity at a given playback time (handles fade in/out).
    func opacity(at time: TimeInterval) -> Double {
        let relativeTime = time - startTime
        guard relativeTime >= 0, relativeTime <= duration else { return 0 }

        // Fade in
        if relativeTime < fadeInDuration {
            return relativeTime / fadeInDuration
        }
        // Fade out
        let fadeOutStart = duration - fadeOutDuration
        if relativeTime > fadeOutStart {
            return (duration - relativeTime) / fadeOutDuration
        }
        return 1.0
    }
}

private struct RGBAColor: Codable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(_ color: CGColor) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let converted = color.converted(to: colorSpace, intent: .defaultIntent, options: nil)
        let components = converted?.components ?? color.components ?? [1, 1, 1, 1]

        if components.count >= 4 {
            red = components[0]
            green = components[1]
            blue = components[2]
            alpha = components[3]
        } else {
            red = components.first ?? 1
            green = components.first ?? 1
            blue = components.first ?? 1
            alpha = components.count > 1 ? components[1] : 1
        }
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
