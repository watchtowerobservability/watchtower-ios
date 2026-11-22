import Foundation

/// Launch profiling (M14): samples the main thread's stack every `intervalMs` from SDK start until
/// the first frame, then reports the hottest folded stacks (`a;b;c count`, root first) as one
/// `app_launch_profile` vital. Opt-in with `Config.profileLaunch`.
final class LaunchSampler {
    private let intervalMs: Int
    private let maxSamples: Int
    private var samples: [[UInt]] = []
    private let lock = NSLock()
    private var running = false

    init(intervalMs: Int = 10, maxSamples: Int = 1000) { self.intervalMs = intervalMs; self.maxSamples = maxSamples }

    func start() {
        running = true
        let t = Thread { [self] in
            while true {
                lock.lock()
                let go = running && samples.count < maxSamples
                lock.unlock()
                if !go { return }
                var stack: [UInt] = []
                ThreadWalker.walk(only: ThreadWalker.mainThread, thread: { _, _ in }, frame: { stack.append($0) })
                lock.lock(); if !stack.isEmpty { samples.append(stack) }; lock.unlock()
                Thread.sleep(forTimeInterval: Double(intervalMs) / 1000)
            }
        }
        t.name = "wt-launch-sampler"
        t.qualityOfService = .utility
        t.start()
    }

    /// Stops sampling; nil when nothing was sampled.
    func stop() -> Event? {
        lock.lock(); running = false; let taken = samples; lock.unlock()
        let folded = Self.fold(taken.map { $0.reversed().map(Self.name) })
        guard !folded.isEmpty else { return nil }
        return Event(type: "vital", name: "app_launch_profile", value: Double(taken.count),
                     attrs: ["profile.folded": folded, "profile.interval_ms": intervalMs])
    }

    /// The symbol covering `addr`, else its hex address.
    static func name(_ addr: UInt) -> String {
        var info = Dl_info()
        if let p = UnsafeRawPointer(bitPattern: addr), dladdr(p, &info) != 0, let s = info.dli_sname { return String(cString: s) }
        return "0x" + String(addr, radix: 16)
    }

    /// Counts identical stacks and keeps the most frequent while the text fits the 2 KiB attribute limit.
    static func fold(_ stacks: [[String]], limit: Int = 2000) -> String {
        var counts: [String: Int] = [:]
        for s in stacks where !s.isEmpty { counts[s.joined(separator: ";"), default: 0] += 1 }
        var out = ""
        for (k, v) in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            let line = "\(k) \(v)\n"
            if out.count + line.count > limit {
                if out.isEmpty { out = String(line.prefix(limit)) }
                break
            }
            out += line
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
