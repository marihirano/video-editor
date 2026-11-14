import Foundation

/// The recording's clock: host time (seconds) → seconds of the recorded video, with pauses cut out.
/// The video's frames and the cursor log both use it, so they line up exactly.
public struct CaptureClock: Equatable, Sendable {
    /// Host time of the first video frame (video time 0). Nil until the first frame arrives.
    public private(set) var start: Double?
    /// Time spent paused so far.
    public private(set) var pausedTotal: Double = 0
    /// Host time the current pause began, if paused.
    public private(set) var pausedAt: Double?

    public init() {}

    public var isPaused: Bool { pausedAt != nil }
    public var hasStarted: Bool { start != nil }

    /// Called with the first frame's time.
    public mutating func begin(at hostTime: Double) { if start == nil { start = hostTime } }

    public mutating func pause(at hostTime: Double) { if pausedAt == nil { pausedAt = hostTime } }

    public mutating func resume(at hostTime: Double) {
        guard let p = pausedAt else { return }
        pausedTotal += max(hostTime - p, 0)
        pausedAt = nil
    }

    /// Video time for a host time, or nil before the first frame or while paused.
    public func videoTime(_ hostTime: Double) -> Double? {
        guard let start, pausedAt == nil else { return nil }
        return max(hostTime - start - pausedTotal, 0)
    }

    /// Length of the recording so far (for the timer), counting up to `hostTime`.
    public func elapsed(_ hostTime: Double) -> Double {
        guard let start else { return 0 }
        let end = pausedAt ?? hostTime
        return max(end - start - pausedTotal, 0)
    }
}
