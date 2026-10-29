import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Crash, hang, app-start and frame metrics. Everything here only calls `Watchtower.record`.
enum Instrument {
    private static var wt: Watchtower?

    static func install(_ c: Config, _ w: Watchtower) {
        wt = w
        crashHandlers()
        hangWatchdog(c.hangThreshold)
        #if canImport(UIKit) && !os(watchOS)
        appStartAndFrames()
        #endif
    }

    /// Objective-C exceptions and fatal signals. The event is written to disk inside the handler
    /// (the signal path writes a fixed small JSON through the same buffer) and sent on next launch.
    private static func crashHandlers() {
        NSSetUncaughtExceptionHandler { e in
            Instrument.wt?.record(Event(type: "error", name: e.name.rawValue, attrs: [
                "error.message": e.reason ?? "",
                "error.stack": e.callStackSymbols.joined(separator: "\n"),
                "crash.class": "mach", "crash.handled": false,
            ]))
        }
        for (sig, name) in [(SIGSEGV, "SIGSEGV"), (SIGABRT, "SIGABRT"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"), (SIGTRAP, "SIGTRAP")] {
            signal(sig) { s in
                Instrument.wt?.record(Event(type: "error", name: "signal \(s)", attrs: [
                    "error.stack": Thread.callStackSymbols.joined(separator: "\n"),
                    "crash.class": "signal", "crash.handled": false,
                ]))
                signal(s, SIG_DFL)
                raise(s)
            }
            _ = name
        }
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
                    Instrument.wt?.record(Event(type: "error", name: "AppHang", attrs: [
                        "crash.class": "anr", "crash.handled": false, "hang.threshold_s": threshold,
                    ]))
                } else if !hung { reported = false }
                Thread.sleep(forTimeInterval: threshold)
            }
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    private static var launched = false
    private static var link: CADisplayLink?
    private static var last: CFTimeInterval = 0
    private static var slow = 0
    private static var frozen = 0

    private static func appStartAndFrames() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if !launched {
                launched = true
                var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
                if sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
                    let start = info.kp_proc.p_un.__p_starttime
                    let t = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
                    wt?.record(Event(type: "vital", name: "app_launch_cold", value: (Date().timeIntervalSince1970 - t) * 1000))
                }
            }
            link = CADisplayLink(target: FrameTicker.shared, selector: #selector(FrameTicker.tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            link?.invalidate(); link = nil; last = 0
            if slow > 0 { wt?.record(Event(type: "vital", name: "slow_frames", value: Double(slow))) }
            if frozen > 0 { wt?.record(Event(type: "vital", name: "frozen_frames", value: Double(frozen))) }
            slow = 0; frozen = 0
            wt?.flush()
        }
    }

    final class FrameTicker: NSObject {
        static let shared = FrameTicker()
        @objc func tick(_ l: CADisplayLink) {
            defer { Instrument.last = l.timestamp }
            guard Instrument.last > 0 else { return }
            let d = l.timestamp - Instrument.last
            if d > 0.7 { Instrument.frozen += 1 } else if d > 0.0167 * 1.5 { Instrument.slow += 1 }
        }
    }
    #endif
}
