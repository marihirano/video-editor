import CoreGraphics
import Foundation

/// The cursor's movement worked out from the log, on the recording's (source) clock: a smoothed
/// path, how visible it is (hide when idle) and how pressed it is. Built once per log + smoothing
/// and cached, because preview and export ask for it every frame.
public final class CursorMotion: @unchecked Sendable {
    /// Path samples per second of recording (the smoothed path is stored at this rate).
    static let rate = 240.0
    private let xs: [Double], ys: [Double]
    /// Moments the hand was active (moved or clicked), sorted.
    private let activity: [Double]
    /// Left/right/other presses with the moment each was released (nil if never).
    private let presses: [(down: Double, up: Double?)]

    public init(track: CursorTrack, smoothing: Double) {
        let samples = track.samples.sorted { $0.time < $1.time }
        let end = max(samples.last?.time ?? 0, track.clicks.map(\.time).max() ?? 0) + 1
        let n = Int(end * Self.rate) + 1
        var xs = [Double](repeating: 0, count: n), ys = xs
        // Raw path: the log only has a sample when the cursor moved, so between two samples far apart the
        // cursor stood still, then moved to the next one over one poll interval.
        let step = 1 / Settings.cursorPollHz
        var j = 0
        for i in 0..<n {
            let t = Double(i) / Self.rate
            while j + 1 < samples.count, samples[j + 1].time <= t { j += 1 }
            guard let a = samples.first else { break }
            if t <= a.time { xs[i] = a.x; ys[i] = a.y; continue }
            let p = samples[j]
            if j + 1 < samples.count {
                let q = samples[j + 1]
                let moveStart = max(p.time, q.time - min(q.time - p.time, step))
                let f = t <= moveStart ? 0 : (t - moveStart) / max(q.time - moveStart, 1e-9)
                xs[i] = p.x + (q.x - p.x) * f; ys[i] = p.y + (q.y - p.y) * f
            } else { xs[i] = p.x; ys[i] = p.y }
        }
        let sigma = max(0, min(1, smoothing)) * Settings.cursorMaxSmoothingSeconds * Self.rate
        self.xs = Self.gaussian(xs, sigma: sigma)
        self.ys = Self.gaussian(ys, sigma: sigma)
        activity = (samples.map(\.time) + track.clicks.map(\.time)).sorted()
        var presses: [(Double, Double?)] = []
        let clicks = track.clicks.sorted { $0.time < $1.time }
        for (i, c) in clicks.enumerated() where c.phase == .down {
            let up = clicks[(i + 1)...].first { $0.phase == .up && $0.button == c.button }?.time
            presses.append((c.time, up))
        }
        self.presses = presses
    }

    /// Bell-curve average of each value with its neighbours (no lag: looks both ways). Three box
    /// averages in a row, which is close to a bell curve and costs the same for any amount of smoothing.
    static func gaussian(_ v: [Double], sigma: Double) -> [Double] {
        guard sigma >= 0.5, v.count > 1 else { return v }
        let r = max(1, Int((sqrt(4 * sigma * sigma + 1) - 1) / 2 + 0.5))   // 3 passes of width 2r+1 ≈ sigma
        var out = v
        let n = v.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for _ in 0..<3 {
            for i in 0..<n { prefix[i + 1] = prefix[i] + out[i] }
            let first = out[0], last = out[n - 1]
            for i in 0..<n {
                // Past either end, the value is held (as if the cursor stood still there).
                let a = i - r, b = i + r
                var s = prefix[min(b, n - 1) + 1] - prefix[max(a, 0)]
                if a < 0 { s += Double(-a) * first }
                if b > n - 1 { s += Double(b - (n - 1)) * last }
                out[i] = s / Double(2 * r + 1)
            }
        }
        return out
    }

    /// Where the (smoothed) cursor is at source time `t`, in recording pixels.
    public func position(at t: Double) -> CGPoint {
        let f = max(0, t) * Self.rate
        let i = min(Int(f), xs.count - 1), k = min(i + 1, xs.count - 1)
        let a = f - Double(i)
        return CGPoint(x: xs[i] + (xs[k] - xs[i]) * a, y: ys[i] + (ys[k] - ys[i]) * a)
    }

    /// 0–1: how visible the cursor is at source time `t` when "hide when idle" is on.
    public func idleOpacity(at t: Double) -> Double {
        let delay = Settings.cursorIdleSeconds, fade = Settings.cursorFadeSeconds
        // Last activity at or before t (the start of the recording counts), and the next one after it.
        var lo = 0, hi = activity.count
        while lo < hi { let m = (lo + hi) / 2; if activity[m] <= t { lo = m + 1 } else { hi = m } }
        let last = lo > 0 ? activity[lo - 1] : 0
        let next = lo < activity.count ? activity[lo] : nil
        let past = 1 - Self.smooth((t - last - delay) / fade)
        let future = next.map { Self.smooth((t - ($0 - fade)) / fade) } ?? 0
        return max(past, future)
    }

    /// 0 = not pressed, 1 = fully pressed (the cursor shrinks a little while a button is held).
    public func pressAmount(at t: Double) -> Double {
        var amount = 0.0
        for p in presses where p.down <= t {
            if let up = p.up, up <= t {
                let held = Self.smooth((up - p.down) / Settings.cursorPressSeconds)
                amount = max(amount, held * (1 - Self.smooth((t - up) / Settings.cursorReleaseSeconds)))
            } else {
                amount = max(amount, Self.smooth((t - p.down) / Settings.cursorPressSeconds))
            }
        }
        return amount
    }

    static func smooth(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }

    // MARK: Cache

    private struct Key: Hashable {
        let count: Int, clicks: Int, first: Double, last: Double, lastX: Double, smoothing: Double
    }
    private static let lock = NSLock()
    private static var cache: [Key: CursorMotion] = [:]

    /// The motion for a log and smoothing amount (built on first use, then reused).
    public static func cached(track: CursorTrack, smoothing: Double) -> CursorMotion {
        let key = Key(count: track.samples.count, clicks: track.clicks.count, first: track.samples.first?.time ?? 0,
                      last: track.samples.last?.time ?? 0, lastX: track.samples.last?.x ?? 0, smoothing: smoothing)
        lock.lock(); defer { lock.unlock() }
        if let m = cache[key] { return m }
        if cache.count > 8 { cache.removeAll() }
        let m = CursorMotion(track: track, smoothing: smoothing)
        cache[key] = m
        return m
    }
}
