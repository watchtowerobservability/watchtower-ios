import Foundation

/// Entry point: `Watchtower.start(Config(key: "...", service: "shop"))` early in app launch.
public final class Watchtower {
    public static let shared = Watchtower()
    public let sessionId = UUID().uuidString.lowercased()
    private var cfg: Config?
    private var buffer: OfflineBuffer?
    private var transport: Transport?
    private let io = DispatchQueue(label: "wt-io", qos: .utility)
    private var replaySeq = 0
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var lastErrorId: String?

    /// Consecutive launches before this one that crashed within 5 s of start; 0 again once this
    /// run passes 5 s. Read it after `start`.
    public internal(set) var launchCrashCount = 0
    /// The app keeps crashing at launch (`launchCrashCount >= Config.crashLoopThreshold`): a cue
    /// for a safe mode, such as skipping remote config or clearing caches.
    public var isCrashLooping: Bool { launchCrashCount >= (cfg?.crashLoopThreshold ?? 2) }

    public static func start(_ config: Config) { shared.start(config) }

    private func start(_ c: Config) {
        guard cfg == nil else { return }
        cfg = c
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("wt-offline")
        let buf = OfflineBuffer(dir: base, maxBytes: c.offlineMaxBytes)
        buffer = buf
        transport = Transport(cfg: c, buffer: buf, session: sessionId, device: deviceInfo())
        let now = Run.current(session: sessionId)
        let prev = Run.start(base.deletingLastPathComponent().appendingPathComponent("wt-run"), now)
        Instrument.install(c, self, previous: prev, now: now)
        if c.trackNetwork {
            NetworkProtocol.config = c
            URLProtocol.registerClass(NetworkProtocol.self)
        }
        if c.replay.enabled { Replay.install(c.replay, self) }
        let t = DispatchSource.makeTimerSource(queue: io)
        t.schedule(deadline: .now() + 5, repeating: 10)
        t.setEventHandler { [weak self] in Run.update { _ in }; self?.transport?.flush() }
        t.resume()
        timer = t
        io.asyncAfter(deadline: .now() + CrashLoop.window) { [weak self] in
            self?.launchCrashCount = 0 // this run survived its launch
            Run.update { $0.launchCrashes = 0 }
        }
        io.async { [weak self] in self?.transport?.flush() } // sends what a crash left on disk last run
    }

    /// Buffer one event after the redaction hook. Durable on return, so it survives a crash.
    public func record(_ e: Event) { record(e, session: sessionId) }

    /// Symbolication and replay links every error carries (an event's own attrs win).
    static func errorLinks(_ c: Config, _ session: String) -> [String: Any] {
        var a: [String: Any] = [:]
        if let b = c.buildId { a["debug.build_id"] = b }
        if c.replay.enabled { a["replay.session_id"] = session } // masked replay as error attachment (M16)
        return a
    }

    /// `session` is the run the event belongs to (an earlier one for what the next launch reports).
    func record(_ e: Event, session: String) {
        guard let c = cfg else { return }
        var e = e
        if e.type == "error" { e.attrs.merge(Self.errorLinks(c, session)) { own, _ in own } }
        guard let out = c.redact(e) else { return }
        var o = out.json()
        o[sessionKey] = session
        if !Synthetic.attrs.isEmpty, var at = o["attrs"] as? [String: Any] {
            at.merge(Synthetic.attrs) { _, run in run }
            o["attrs"] = at
        }
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        buffer?.add(d)
        if out.type == "error" { lock.lock(); lastErrorId = out.id; lock.unlock() }
    }

    /// User feedback (ERR-014) about `eventId`, by default the last error recorded. Sent off the
    /// main thread; `done` (called on a background queue) gets true when the edge accepted it.
    public func feedback(_ message: String, name: String? = nil, email: String? = nil, eventId: String? = nil,
                         done: ((Bool) -> Void)? = nil) {
        lock.lock(); let last = lastErrorId; lock.unlock()
        guard let b = feedbackBody(message: message, name: name, email: email, eventId: eventId ?? last),
              let body = try? JSONSerialization.data(withJSONObject: b) else { done?(false); return }
        io.async { [weak self] in
            let code = self?.transport?.post("/v1/rum/feedback", body: body)
            done?(code.map { $0 < 300 } ?? false)
        }
    }

    /// Adds URLSession capture to a custom session's configuration (`URLSession.shared` has it).
    public static func instrument(_ configuration: URLSessionConfiguration) {
        configuration.protocolClasses = [NetworkProtocol.self as AnyClass] + (configuration.protocolClasses ?? [])
    }

    public func recordError(_ error: Error, handled: Bool = true) {
        record(Event(type: "error", name: String(describing: type(of: error)),
                     attrs: ["error.message": "\(error)", "crash.handled": handled]))
    }

    public func flush() { io.async { [weak self] in self?.transport?.flush() } }

    /// Uploads one replay chunk (a JSON array of rrweb events) for this session.
    func postReplay(_ events: [[String: Any]]) {
        guard let c = cfg, let body = try? JSONSerialization.data(withJSONObject: events) else { return }
        io.async { [self] in
            let seq = replaySeq
            replaySeq += 1
            _ = transport?.post("/v1/replay/\(sessionId)/chunks?seq=\(seq)", body: body,
                                headers: ["X-Wt-Mask": c.replay.maskText ? "strict" : "balanced"])
        }
    }

    private func deviceInfo() -> [String: Any] {
        var u = utsname(); uname(&u)
        let model = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let os = "iOS"
        #else
        let os = "macOS"
        #endif
        return ["ua": model, "os.name": os, "os.version": "\(v.majorVersion).\(v.minorVersion)", "device.model": model]
    }
}
