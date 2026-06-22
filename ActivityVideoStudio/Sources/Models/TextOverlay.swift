import Foundation
import CoreGraphics

/// A text overlay to be displayed at a specific time range on the video.
struct TextOverlay: Identifiable, Codable {
    let id: UUID
    var text: String
    var startTime: TimeInterval      // seconds from video start
    var duration: TimeInterval = 15   // how long to display
    var fontSize: CGFloat = 48
    var position: Position = .center
    var color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    var backgroundColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.3)
    var fadeInDuration: TimeInterval = 0
    var fadeOutDuration: TimeInterval = 0.5

    enum Position: String, CaseIterable, Codable {
        case topCenter = "上中央"
        case center = "中央"
        case bottomCenter = "下中央"
    }

    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval = 15,
        fontSize: CGFloat = 48,
        position: Position = .center,
        color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        backgroundColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.3),
        fadeInDuration: TimeInterval = 0,
        fadeOutDuration: TimeInterval = 0.5
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.fontSize = fontSize
        self.position = position
        self.color = color
        self.backgroundColor = backgroundColor
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, startTime, duration, fontSize, position, color, backgroundColor, fadeInDuration, fadeOutDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fontSize = try container.decode(CGFloat.self, forKey: .fontSize)
        position = try container.decode(Position.self, forKey: .position)
        color = try container.decode(RGBAColor.self, forKey: .color).cgColor
        backgroundColor = try container.decode(RGBAColor.self, forKey: .backgroundColor).cgColor
        fadeInDuration = try container.decode(TimeInterval.self, forKey: .fadeInDuration)
        fadeOutDuration = try container.decode(TimeInterval.self, forKey: .fadeOutDuration)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(duration, forKey: .duration)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(position, forKey: .position)
        try container.encode(RGBAColor(color), forKey: .color)
        try container.encode(RGBAColor(backgroundColor), forKey: .backgroundColor)
        try container.encode(fadeInDuration, forKey: .fadeInDuration)
        try container.encode(fadeOutDuration, forKey: .fadeOutDuration)
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
