import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Crash, hang, app-start, frame metrics and screen views. Everything here only calls
/// `Watchtower.record`, plus `Run.update` so the next launch knows how this run ended.
enum Instrument {
    private static var wt: Watchtower?
    /// This run's start (seconds since 1970), read by the exception handler, which cannot capture.
    private static var launchedAt: Double = 0

    static func install(_ c: Config, _ w: Watchtower, previous: RunState?, now: RunState) {
        wt = w
        crashHandlers(previous: previous, now: now)
        hangWatchdog(c.hangThreshold)
        #if canImport(MetricKit) && os(iOS)
        if c.metricKit, #available(iOS 14, *) { MetricKitSubscriber.install(w) }
        #endif
        #if canImport(UIKit) && !os(watchOS)
        if c.trackViews { ViewTracking.install(c.service) }
        if c.profileLaunch { sampler = LaunchSampler(); sampler?.start() }
        appStartAndFrames()
        #endif
    }

    /// Objective-C exceptions and fatal signals. An uncaught exception is recorded (durably, on
    /// disk) from its handler, which is not a signal context. Fatal signals go through
    /// `CrashReport`, whose handler is async-signal-safe; last launch's report is recorded here.
    /// The previous run's crash report and session end are recorded under that run's session.
    private static func crashHandlers(previous: RunState?, now: RunState) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("wt-crash")
        let report = CrashReport.collect(dir)
        launchedAt = now.launchedAt ?? now.last
        let loops = CrashLoop.count(previous: previous, crashed: report != nil || previous?.crashed == true)
        wt?.launchCrashCount = loops
        Run.update { $0.launchCrashes = loops }
        if let p = previous {
            if var e = report {
                if let age = CrashLoop.launchCrashAge(p, crashed: true) {
                    e.attrs.merge(CrashLoop.attrs(sinceLaunch: age, loopCount: loops)) { _, tag in tag }
                }
                wt?.record(e, session: p.session)
            }
            let reason = SessionEnd.reason(previous: p, now: now, crashReport: report != nil)
            if let e = SessionEnd.errorFor(reason, p) { wt?.record(e, session: p.session) }
            wt?.record(SessionEnd.endEvent(reason, p), session: p.session)
        } else if let e = report {
            wt?.record(e)
        }
        NSSetUncaughtExceptionHandler { e in
            CrashReport.exceptionRecorded = 1
            Run.update { $0.crashed = true }
            var attrs: [String: Any] = [
                "error.message": e.reason ?? "",
                "error.stack": e.callStackSymbols.joined(separator: "\n"),
                "crash.class": "mach", "crash.handled": false,
            ]
            let launch = CrashLoop.attrs(sinceLaunch: Date().timeIntervalSince1970 - Instrument.launchedAt,
                                         loopCount: (Instrument.wt?.launchCrashCount ?? 0) + 1)
            attrs.merge(launch) { _, tag in tag }
            // parsed frames (return addresses: the server symbolicates them with the dSYM) and what the other threads were doing
            let stack = e.callStackReturnAddresses.map { UInt64(truncating: $0) }
            let others = ThreadWalker.snapshot().threads
            attrs.merge(NativeStacks.attrs(stack: stack, threads: others, images: Images.loaded())) { _, w in w }
            Instrument.wt?.record(Event(type: "error", name: e.name.rawValue, attrs: attrs))
        }
        CrashReport.install(dir)
    }

    /// Pings the main queue; if it does not answer within the threshold the app is hanging (ANR analogue).
    private static func hangWatchdog(_ threshold: TimeInterval) {
        let q = DispatchQueue(label: "wt-hang", qos: .utility)
        q.async {
            var reported = false
            while true {
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                let hung = sem.wait(timeout: .now() + threshold) == .timedOut
                if hung && !reported {
                    reported = true
                    Run.update { $0.hanging = true }
                    Instrument.wt?.record(Event(type: "error", name: "AppHang", attrs: Instrument.hangAttrs(threshold)))
                } else if !hung && reported {
                    reported = false
                    Run.update { $0.hanging = false }
                }
                Thread.sleep(forTimeInterval: threshold)
            }
        }
    }

    /// The hang event's attributes: the main thread's stack is the error stack (where it is stuck),
    /// the other threads ride along.
    static func hangAttrs(_ threshold: TimeInterval) -> [String: Any] {
        var a: [String: Any] = ["crash.class": "anr", "crash.handled": false, "hang.threshold_s": threshold,
                                "error.message": "Main thread unresponsive for \(threshold) s"]
        let snap = ThreadWalker.snapshot()
        let main = snap.mainIndex.map { snap.threads[$0] }
        let others = snap.threads.enumerated().filter { $0.offset != snap.mainIndex }.map { $0.element }
        if let m = main {
            a["error.stack"] = m.map { NativeStacks.hex($0) }.joined(separator: "\n")
        }
        a.merge(NativeStacks.attrs(stack: main, threads: others, images: Images.loaded())) { _, w in w }
        return a
    }

    #if canImport(UIKit) && !os(watchOS)
    private static var link: CADisplayLink?
    private static var last: CFTimeInterval = 0
    private static var slow = 0
    private static var frozen = 0
    static var launch: LaunchTracker?
    private static var sampler: LaunchSampler?

    /// Process start from the kernel, seconds since 1970.
    private static func processStart() -> Double? {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1e6
    }

    private static func appStartAndFrames() {
        let now = { Date().timeIntervalSince1970 }
        let sdk = now()
        let prewarmed = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
        launch = LaunchTracker(processStart: processStart() ?? sdk, sdkStart: sdk, prewarmed: prewarmed)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            launch?.didFinishLaunching(now())
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            launch?.willEnterForeground(now())
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Run.update { $0.foreground = false }
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Run.update { $0.cleanExit = true }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Run.update { $0.foreground = true }
            launch?.didBecomeActive(now())
            link = CADisplayLink(target: FrameTicker.shared, selector: #selector(FrameTicker.tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            link?.invalidate(); link = nil; last = 0
            let screen: [String: Any] = ViewTracking.tracker?.current.map { ["screen": $0] } ?? [:]
            if slow > 0 { wt?.record(Event(type: "vital", name: "slow_frames", value: Double(slow), attrs: screen)) }
            if frozen > 0 { wt?.record(Event(type: "vital", name: "frozen_frames", value: Double(frozen), attrs: screen)) }
            slow = 0; frozen = 0
            wt?.flush()
        }
    }

    final class FrameTicker: NSObject {
        static let shared = FrameTicker()
        @objc func tick(_ l: CADisplayLink) {
            defer { Instrument.last = l.timestamp }
            // the first tick after becoming active ends a launch (once)
            if let e = Instrument.launch?.firstFrame(Date().timeIntervalSince1970) {
                Instrument.wt?.record(e)
                if e.name == "app_launch_cold", let p = Instrument.sampler?.stop() { Instrument.wt?.record(p) }
                Instrument.sampler = nil
            }
            guard Instrument.last > 0 else { return }
            let d = l.timestamp - Instrument.last
            if d > 0.7 { Instrument.frozen += 1 } else if d > 0.0167 * 1.5 { Instrument.slow += 1 }
        }
    }
    #endif
}
