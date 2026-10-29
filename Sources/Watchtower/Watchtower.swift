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

    public static func start(_ config: Config) { shared.start(config) }

    private func start(_ c: Config) {
        guard cfg == nil else { return }
        cfg = c
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("wt-offline")
        let buf = OfflineBuffer(dir: base, maxBytes: c.offlineMaxBytes)
        buffer = buf
        transport = Transport(cfg: c, buffer: buf, session: sessionId, device: deviceInfo())
        Instrument.install(c, self)
        if c.replay.enabled { Replay.install(c.replay, self) }
        let t = DispatchSource.makeTimerSource(queue: io)
        t.schedule(deadline: .now() + 5, repeating: 10)
        t.setEventHandler { [weak self] in self?.transport?.flush() }
        t.resume()
        timer = t
        io.async { [weak self] in self?.transport?.flush() } // sends what a crash left on disk last run
    }

    /// Buffer one event after the redaction hook. Durable on return, so it survives a crash.
    public func record(_ e: Event) {
        guard let c = cfg, let out = c.redact(e),
              let d = try? JSONSerialization.data(withJSONObject: out.json()) else { return }
        buffer?.add(d)
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
