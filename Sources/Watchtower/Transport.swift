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
        let events = batch.compactMap { (try? JSONSerialization.jsonObject(with: $0.1)) as? [String: Any] }
        guard let body = try? batchBody(cfg, session: session, device: device, events: events),
              let status = post("/v1/rum/events", body: body) else { return }
        if status < 300 { failures = 0; buffer.remove(batch.map { $0.0 }) }
        else if status == 429 || status >= 500 { backoff() }
        else { buffer.remove(batch.map { $0.0 }) } // other 4xx: invalid batch, retrying cannot help
    }

    /// POST a JSON body (synchronous, call off the main thread); nil when the network is down.
    func post(_ path: String, body: Data, headers: [String: String] = [:]) -> Int? {
        guard let url = URL(string: cfg.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
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
