import Foundation

/// Crash-loop guard (DX 15). A crash within `window` seconds of the SDK start is a launch crash;
/// `RunState.launchCrashes` counts consecutive launches that ended in one, so the app can enter a
/// safe mode (`Watchtower.shared.isCrashLooping`). Pure, so it is unit tested.
public enum CrashLoop {
    public static let window: Double = 5

    /// Seconds from launch to the previous run's crash, when it crashed inside the window. A signal
    /// crash has no time of its own: `last` is the last sign of life, and a run that passed the
    /// window always wrote one after it (the reset at `window` seconds).
    public static func launchCrashAge(_ p: RunState, crashed: Bool) -> Double? {
        guard crashed, let at = p.launchedAt else { return nil }
        let age = max(0, p.last - at)
        return age < window ? age : nil
    }

    /// This run's count: the previous run's plus one after a launch crash, else 0.
    public static func count(previous p: RunState?, crashed: Bool) -> Int {
        guard let p, launchCrashAge(p, crashed: crashed) != nil else { return 0 }
        return (p.launchCrashes ?? 0) + 1
    }

    /// The launch tags of a crash `sinceLaunch` seconds after start; empty outside the window.
    public static func attrs(sinceLaunch s: Double, loopCount: Int) -> [String: Any] {
        guard s >= 0, s < window else { return [:] }
        return ["crash.launch": true, "crash.since_launch_ms": Int((s * 1000).rounded()), "crash.loop_count": loopCount]
    }
}
