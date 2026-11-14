import Foundation

/// How the cursor is drawn over a recording made in the app (P2). Saved as `cursorLook` in project.json;
/// every field has a default, so older projects open with the default cursor.
/// Imported videos have no cursor log, so these settings are never shown or used for them.
public struct CursorLook: Codable, Equatable, Sendable {
    /// The cursor's colours: black with a white edge (like the Mac's own), white with a black edge, or a soft dot.
    public enum Style: String, Codable, CaseIterable, Sendable { case black, white, dot }
    /// What a click shows: nothing, a circle that pops and fades, or a ring that spreads out.
    public enum ClickEffect: String, Codable, CaseIterable, Sendable { case none, circle, ripple }

    /// Draw the cursor at all.
    public var show: Bool = true
    public var style: Style = Settings.defaultCursorStyle
    /// 1 = the size the pointer had on screen while recording.
    public var size: Double = Settings.defaultCursorSize
    /// 0 = follows the hand exactly, 1 = the smoothest glide.
    public var smoothing: Double = Settings.defaultCursorSmoothing
    /// 0 = no blur, 1 = the most blur on fast movement.
    public var motionBlur: Double = Settings.defaultCursorMotionBlur
    public var clickEffect: ClickEffect = Settings.defaultCursorClickEffect
    /// Fade the cursor out when it hasn't moved for a while (it fades back in just before it moves).
    public var hideWhenIdle: Bool = Settings.defaultCursorHideWhenIdle

    public init() {}

    enum CodingKeys: String, CodingKey { case show, style, size, smoothing, motionBlur, clickEffect, hideWhenIdle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CursorLook()
        show = try c.decodeIfPresent(Bool.self, forKey: .show) ?? d.show
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? d.style
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        motionBlur = try c.decodeIfPresent(Double.self, forKey: .motionBlur) ?? d.motionBlur
        clickEffect = (try? c.decodeIfPresent(ClickEffect.self, forKey: .clickEffect)) ?? d.clickEffect
        hideWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? d.hideWhenIdle
    }
}
