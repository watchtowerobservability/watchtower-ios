import Foundation

/// What the SDK knows about one run, kept on disk so the next launch can end its session.
public struct RunState: Codable, Equatable {
    public var session: String
    /// Seconds since 1970 of the last sign of life.
    public var last: Double
    public var foreground = false
    /// The hang watchdog sees the main thread blocked right now.
    public var hanging = false
    /// An uncaught exception was recorded.
    public var crashed = false
    /// `willTerminate` arrived: the user or the system closed the app normally.
    public var cleanExit = false
    public var appVersion: String
    public var osVersion: String
    /// Kernel boot time, seconds since 1970; a different one means the device rebooted.
    public var bootTime: Double
    /// Seconds since 1970 when the SDK started this run (crash-loop guard); nil in older files.
    public var launchedAt: Double?
    /// Consecutive launch crashes before this run (`CrashLoop.count`); nil in older files.
    public var launchCrashes: Int?

    public init(session: String, last: Double, appVersion: String, osVersion: String, bootTime: Double) {
        self.session = session; self.last = last
        self.appVersion = appVersion; self.osVersion = osVersion; self.bootTime = bootTime
    }
}

/// How the previous session ended (RUM-009), sent as `session.end_reason` on a `session_end`
/// event of that session. The next-launch heuristic: a crash report or recorded exception is a
/// crash; `willTerminate`, an app or OS upgrade or a reboot is a normal end (user_exit, or
/// background_timeout when it happened in the background). Anything else is a termination iOS
/// gives no callback for: in the foreground an OOM (a watchdog kill when the main thread hung),
/// in the background a watchdog termination.
public enum SessionEnd {
    public static func reason(previous p: RunState, now c: RunState, crashReport: Bool) -> String {
        if p.crashed || crashReport { return "crash" }
        let upgraded = p.appVersion != c.appVersion || p.osVersion != c.osVersion
        let rebooted = abs(p.bootTime - c.bootTime) > 5
        if p.cleanExit || upgraded || rebooted { return p.foreground ? "user_exit" : "background_timeout" }
        if p.foreground { return p.hanging ? "watchdog" : "oom" }
        return "watchdog"
    }

    static func endEvent(_ reason: String, _ p: RunState) -> Event {
        var e = Event(type: "action", name: "session_end",
                      attrs: ["session.end_reason": reason, "app.in_foreground": p.foreground])
        e.tsNs = Int64(p.last * 1e9)
        return e
    }

    /// The error event for a termination only this heuristic sees. Foreground only: background
    /// terminations include force-quits from the app switcher, which are no failure.
    static func errorFor(_ reason: String, _ p: RunState) -> Event? {
        guard p.foreground, reason == "oom" || reason == "watchdog" else { return nil }
        let oom = reason == "oom"
        var e = Event(type: "error", name: oom ? "OutOfMemory" : "WatchdogTermination", attrs: [
            "crash.class": oom ? "oom" : "watchdog_termination", "crash.handled": false,
            "crash.previous_session": true, "app.in_foreground": true,
        ])
        e.tsNs = Int64(p.last * 1e9)
        return e
    }
}

/// This run's `RunState` file; the hooks in `Instrument` keep it current.
enum Run {
    private static let lock = NSLock()
    private static var file: URL?
    private static var state: RunState?

    /// Starts this run and returns the previous one, if it left a state behind.
    static func start(_ dir: URL, _ now: RunState) -> RunState? {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("wt-run.json")
        file = f
        let prev = (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode(RunState.self, from: $0) }
        state = now
        write()
        return prev
    }

    static func update(_ fn: (inout RunState) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var s = state else { return }
        fn(&s)
        s.last = Date().timeIntervalSince1970
        state = s
        write()
    }

    private static func write() {
        guard let f = file, let s = state, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: f, options: .atomic)
    }

    static func current(session: String) -> RunState {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] ?? "")+\(info?["CFBundleVersion"] ?? "")"
        let t = Date().timeIntervalSince1970
        var r = RunState(session: session, last: t, appVersion: app,
                         osVersion: ProcessInfo.processInfo.operatingSystemVersionString, bootTime: bootTime())
        r.launchedAt = t
        return r
    }

    private static func bootTime() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }
}
