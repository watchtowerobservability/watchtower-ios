import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// MetricKit diagnostics (ERR-017) as error events. iOS delivers them on a later launch, so they
/// also cover crashes the in-process handlers miss (watchdog kills, crashes before `start`).
/// The mapping is pure, over the payload's `jsonRepresentation()` dictionary, so it is unit tested.
/// A crash may arrive twice, from our own signal report and from MetricKit: the MetricKit copy is
/// tagged `crash.source: metrickit` (ours has no `crash.source`) instead of being deduplicated.
public enum MetricKitMap {
    /// Error events of one diagnostic payload; `begin` is the payload's `timeStampBegin`.
    public static func events(_ payload: [String: Any], begin: Date) -> [Event] {
        let list = { (k: String) in payload[k] as? [[String: Any]] ?? [] }
        let all = list("crashDiagnostics").map(crash) + list("hangDiagnostics").map(hang)
            + list("cpuExceptionDiagnostics").map(cpu)
        return all.map { e in
            var e = e
            e.tsNs = Int64(begin.timeIntervalSince1970 * 1e9)
            return e
        }
    }

    static func crash(_ d: [String: Any]) -> Event {
        let m = meta(d)
        let sig = (m["signal"] as? NSNumber)?.intValue
        let type = (m["exceptionType"] as? NSNumber)?.intValue
        let code = (m["exceptionCode"] as? NSNumber)?.intValue
        let name = sig.map { "signal \($0)" } ?? type.map { "EXC \($0)" } ?? "crash"
        var message = m["terminationReason"] as? String ?? ""
        if message.isEmpty, let type { message = "exception type \(type) code \(code ?? 0)" }
        if message.isEmpty, let sig { message = "signal \(sig)" }
        return event(name, d, ["crash.class": sig != nil ? "signal" : "mach", "error.message": message])
    }

    static func hang(_ d: [String: Any]) -> Event {
        var a: [String: Any] = ["crash.class": "anr", "error.message": "main thread hang"]
        if let s = seconds(meta(d)["hangDuration"]) { a["hang.duration_s"] = s }
        return event("AppHang", d, a)
    }

    static func cpu(_ d: [String: Any]) -> Event {
        var a: [String: Any] = ["crash.class": "cpu_exception", "error.message": "CPU usage limit exceeded"]
        if let s = seconds(meta(d)["totalCPUTime"]) { a["cpu.total_time_s"] = s }
        if let s = seconds(meta(d)["totalSampledTime"]) { a["cpu.total_sampled_time_s"] = s }
        return event("CPUException", d, a)
    }

    private static func meta(_ d: [String: Any]) -> [String: Any] { d["diagnosticMetaData"] as? [String: Any] ?? [:] }

    private static func event(_ name: String, _ d: [String: Any], _ extra: [String: Any]) -> Event {
        let m = meta(d)
        var a: [String: Any] = ["crash.handled": false, "crash.previous_session": true, "crash.source": "metrickit",
                                "error.stack": stack(d["callStackTree"] as? [String: Any] ?? [:])]
        if let v = m["appVersion"] as? String { a["app.version"] = v }
        if let v = m["appBuildVersion"] as? String { a["app.build"] = v }
        if let v = m["osVersion"] as? String { a["os.version"] = v }
        a.merge(extra) { _, x in x }
        return Event(type: "error", name: name, attrs: a)
    }

    /// The attributed (crashed) thread's frames, else the first thread's, one line each:
    /// `binaryName 0xaddress (offsetIntoBinaryTextSegment) binaryUUID`, innermost first.
    static func stack(_ tree: [String: Any]) -> String {
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        let thread = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var lines: [String] = []
        func walk(_ frames: [[String: Any]]) {
            for f in frames where lines.count < 128 {
                let addr = (f["address"] as? NSNumber)?.uint64Value ?? 0
                let off = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
                lines.append("\(f["binaryName"] as? String ?? "???") 0x\(String(addr, radix: 16)) (\(off)) \(f["binaryUUID"] as? String ?? "")")
                walk(f["subFrames"] as? [[String: Any]] ?? [])
            }
        }
        walk(thread?["callStackRootFrames"] as? [[String: Any]] ?? [])
        return lines.joined(separator: "\n")
    }

    /// A MetricKit measurement as seconds: a number, or text such as "4 sec", "1,500 ms", "2 min".
    static func seconds(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        guard let s = v as? String else { return nil }
        let parts = s.replacingOccurrences(of: ",", with: "").split(separator: " ")
        guard let first = parts.first, let n = Double(first) else { return nil }
        switch parts.dropFirst().first.map(String.init) {
        case "ms": return n / 1000
        case "min": return n * 60
        default: return n
        }
    }
}

#if canImport(MetricKit) && os(iOS)
@available(iOS 14, *)
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitSubscriber()
    private weak var wt: Watchtower?

    static func install(_ w: Watchtower) {
        shared.wt = w
        MXMetricManager.shared.add(shared)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            guard let o = (try? JSONSerialization.jsonObject(with: p.jsonRepresentation())) as? [String: Any] else { continue }
            MetricKitMap.events(o, begin: p.timeStampBegin).forEach { wt?.record($0) }
        }
        wt?.flush()
    }
}
#endif
