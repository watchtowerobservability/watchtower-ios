import Foundation

/// One RUM event in the `RumEventV1` wire shape.
public struct Event {
    public var type: String
    public var name: String
    public var value: Double?
    public var attrs: [String: Any]
    public var id = UUID().uuidString.lowercased()
    public var tsNs = Int64(Date().timeIntervalSince1970 * 1e9)
    /// 32 lowercase hex chars, for a `resource` event that carried a `traceparent`.
    public var traceId: String?
    /// 16 lowercase hex chars.
    public var spanId: String?

    public init(type: String, name: String, value: Double? = nil, attrs: [String: Any] = [:]) {
        self.type = type; self.name = name; self.value = value; self.attrs = attrs
    }

    func json() -> [String: Any] {
        var o: [String: Any] = ["id": id, "ts_ns": tsNs, "type": type, "name": name, "attrs": safeAttrs(attrs)]
        if let v = value { o["value"] = v }
        if let t = traceId { o["trace_id"] = t }
        if let s = spanId { o["span_id"] = s }
        return o
    }
}

/// Buffer-only field: the session an event belongs to. `Transport` strips it before sending.
let sessionKey = "_sid"

/// App attributes must not use the `wt.` namespace: the gateway deletes incoming `wt.*` keys, so
/// they would only be lost. They are removed here and string values are cut to the wire limit.
public func safeAttrs(_ a: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in a where !k.hasPrefix("wt.") && k.count <= 128 {
        let cap = crashAttrKeys.contains(k) ? 32_768 : 2048 // the edge's limits for crash attributes
        if let s = v as? String, s.count > cap { out[k] = String(s.prefix(cap)) } else { out[k] = v }
    }
    return out
}

/// Attributes the edge lets run to 32 KiB (stacks cut mid-JSON would be unusable).
let crashAttrKeys: Set<String> = ["error.stack", "stack", "frames", "threads", "error.threads", "debug_images"]

func batchBody(_ c: Config, session: String, device: [String: Any], events: [[String: Any]]) throws -> Data {
    var app: [String: Any] = ["service": c.service]
    if let r = c.release { app["release"] = r }
    if let e = c.environment { app["env"] = e }
    let o: [String: Any] = [
        "session_id": session,
        "sent_at_ns": Int64(Date().timeIntervalSince1970 * 1e9),
        "sdk": ["name": sdkName, "version": sdkVersion],
        "app": app,
        "page": ["url": "app://\(c.service)"],
        "device": ["ua": device["ua"] ?? "ios"],
        "attrs": safeAttrs(device),
        "events": events,
    ]
    return try JSONSerialization.data(withJSONObject: o)
}
