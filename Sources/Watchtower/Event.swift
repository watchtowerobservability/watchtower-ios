import Foundation

/// One RUM event in the `RumEventV1` wire shape.
public struct Event {
    public var type: String
    public var name: String
    public var value: Double?
    public var attrs: [String: Any]
    public var id = UUID().uuidString.lowercased()
    public var tsNs = Int64(Date().timeIntervalSince1970 * 1e9)

    public init(type: String, name: String, value: Double? = nil, attrs: [String: Any] = [:]) {
        self.type = type; self.name = name; self.value = value; self.attrs = attrs
    }

    func json() -> [String: Any] {
        var o: [String: Any] = ["id": id, "ts_ns": tsNs, "type": type, "name": name, "attrs": safeAttrs(attrs)]
        if let v = value { o["value"] = v }
        return o
    }
}

/// App attributes must not use the `wt.` namespace: the gateway deletes incoming `wt.*` keys, so
/// they would only be lost. They are removed here and string values are cut to the wire limit.
public func safeAttrs(_ a: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in a where !k.hasPrefix("wt.") && k.count <= 128 {
        if let s = v as? String, s.count > 2048 { out[k] = String(s.prefix(2048)) } else { out[k] = v }
    }
    return out
}

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
