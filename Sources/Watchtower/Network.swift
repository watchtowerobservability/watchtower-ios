import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Network capture helpers (RUM-010). Pure, so they are unit tested.
public enum Network {
    /// Query and fragment dropped: both can carry tokens.
    public static func scrubUrl(_ u: String) -> String {
        guard let i = u.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return u }
        return String(u[..<i])
    }

    /// The edge itself is never captured and never gets a trace header.
    static func isOwn(_ url: String, _ c: Config) -> Bool {
        url.hasPrefix(c.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// Prefix match against `Config.propagateTo`; nothing is implicit.
    public static func shouldPropagate(_ url: String, _ c: Config) -> Bool {
        !url.isEmpty && !isOwn(url, c) && c.propagateTo.contains { !$0.isEmpty && url.hasPrefix($0) }
    }

    static func hex(_ bytes: Int) -> String {
        var b = (0..<bytes).map { _ in UInt8.random(in: 0...255) }
        if b.allSatisfy({ $0 == 0 }) { b[bytes - 1] = 1 } // all-zero ids are invalid in W3C
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func traceparent(_ trace: String, _ span: String) -> String { "00-\(trace)-\(span)-01" }

    /// (trace id, span id) from an existing `traceparent`, or nil when it is malformed.
    static func parseTraceparent(_ h: String) -> (String, String)? {
        let p = h.trimmingCharacters(in: .whitespaces).split(separator: "-").map(String.init)
        guard p.count >= 4, p[1].count == 32, p[2].count == 16,
              (p[1] + p[2]).allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return (p[1], p[2])
    }

    /// One RUM `resource` event (browser shape: name = initiator type, value = duration ms).
    static func resourceEvent(url: String, method: String, status: Int?, durationMs: Double, bytes: Int64?,
                              start: Date, ids: (String, String)?) -> Event {
        var a: [String: Any] = ["url": scrubUrl(url), "method": method.uppercased(), "initiator_type": "native"]
        if let s = status { a["status"] = s }
        if let b = bytes, b >= 0 { a["transfer_size"] = b }
        if status.map({ $0 >= 400 }) ?? true { a["failed"] = true }
        var e = Event(type: "resource", name: "native", value: max(0, durationMs).rounded(), attrs: a)
        e.tsNs = Int64(start.timeIntervalSince1970 * 1e9)
        e.traceId = ids?.0
        e.spanId = ids?.1
        return e
    }
}

/// URLSession capture: a URLProtocol that re-issues each http(s) request (marked so it is not
/// captured twice), adds `traceparent` for `propagateTo` hosts and records a `resource` event.
/// Registered for `URLSession.shared`; a custom session opts in with
/// `Watchtower.instrument(configuration)`.
/// shortcut: the inner session uses the default configuration and follows redirects itself;
/// a custom session's own delegate (auth challenges, redirects) is bypassed for captured requests.
final class NetworkProtocol: URLProtocol, URLSessionDataDelegate {
    private static let mark = "dev.watchtower.captured"
    static var config: Config?
    private var session: URLSession?
    private var start = Date()
    private var bytes: Int64 = 0
    private var status: Int?
    private var ids: (String, String)?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let c = config, let url = request.url?.absoluteString,
              url.hasPrefix("http://") || url.hasPrefix("https://"),
              URLProtocol.property(forKey: mark, in: request) == nil else { return false }
        return !Network.isOwn(url, c)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let c = Self.config, let copy = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.mark, in: copy)
        let url = request.url?.absoluteString ?? ""
        if let h = copy.value(forHTTPHeaderField: "traceparent") {
            ids = Network.parseTraceparent(h)
        } else if Network.shouldPropagate(url, c) {
            let t = (Network.hex(16), Network.hex(8))
            ids = t
            copy.setValue(Network.traceparent(t.0, t.1), forHTTPHeaderField: "traceparent")
        }
        start = Date()
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.dataTask(with: copy as URLRequest).resume()
    }

    override func stopLoading() { session?.invalidateAndCancel(); session = nil }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes += Int64(data.count)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { client?.urlProtocol(self, didFailWithError: e) } else { client?.urlProtocolDidFinishLoading(self) }
        let e = Network.resourceEvent(url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "GET",
                                      status: error == nil ? status : nil,
                                      durationMs: Date().timeIntervalSince(start) * 1000, bytes: bytes,
                                      start: start, ids: ids)
        Watchtower.shared.record(e)
        s.finishTasksAndInvalidate()
    }
}
