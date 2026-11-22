import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends buffered events to the edge. Never throws; a failed send leaves the events on disk.
final class Transport {
    private let cfg: Config
    private let buffer: OfflineBuffer
    private let session: String
    private let device: [String: Any]
    private var retryAt = Date.distantPast
    private var failures = 0

    init(cfg: Config, buffer: OfflineBuffer, session: String, device: [String: Any]) {
        self.cfg = cfg; self.buffer = buffer; self.session = session; self.device = device
    }

    func flush() {
        guard Date() >= retryAt else { return }
        let batch = buffer.peek(200)
        guard !batch.isEmpty else { return }
        // one batch per session: events a previous run left on disk keep that run's session
        var groups: [String: [(URL, [String: Any])]] = [:]
        var unreadable: [URL] = []
        for (u, d) in batch {
            guard var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { unreadable.append(u); continue }
            let sid = (o.removeValue(forKey: sessionKey) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            groups[sid, default: []].append((u, o))
        }
        buffer.remove(unreadable)
        for (sid, items) in groups {
            guard let body = try? batchBody(cfg, session: sid, device: device, events: items.map { $0.1 }),
                  let status = post("/v1/rum/events", body: body) else { return }
            if status < 300 { failures = 0; buffer.remove(items.map { $0.0 }) }
            else if status == 429 || status >= 500 { backoff(); return }
            else { buffer.remove(items.map { $0.0 }) } // other 4xx: invalid batch, retrying cannot help
        }
    }

    /// The request `post` sends. A native app has no Origin, so the edge accepts the publishable key
    /// only with the bundle id on the key's app id list (`X-Watchtower-App-Id`).
    func request(_ path: String, body: Data, headers: [String: String] = [:]) -> URLRequest? {
        guard let url = URL(string: cfg.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let app = Bundle.main.bundleIdentifier { r.setValue(app, forHTTPHeaderField: "X-Watchtower-App-Id") }
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        return r
    }

    /// POST a JSON body (synchronous, call off the main thread); nil when the network is down.
    func post(_ path: String, body: Data, headers: [String: String] = [:]) -> Int? {
        guard let r = request(path, body: body, headers: headers) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var code: Int?
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            code = (resp as? HTTPURLResponse)?.statusCode
            sem.signal()
        }.resume()
        sem.wait()
        if code == nil { backoff() }
        return code
    }

    private func backoff() {
        failures += 1
        retryAt = Date().addingTimeInterval(min(300, Double(1 << min(failures, 8))))
    }
}
