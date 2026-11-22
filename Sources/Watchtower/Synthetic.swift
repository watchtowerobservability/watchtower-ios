import Foundation

/// Marks the RUM of a Watchtower mobile check run as synthetic (UPT-006): the check launches the
/// app with `WT_SYNTHETIC_RUN_ID` (and `WT_SYNTHETIC_CHECK_ID`) in its environment, and every
/// event then carries `synthetic.run_id`, so the run links to this session.
enum Synthetic {
    static let attrs: [String: Any] = from(ProcessInfo.processInfo.environment)

    static func from(_ env: [String: String]) -> [String: Any] {
        guard let run = env["WT_SYNTHETIC_RUN_ID"], !run.isEmpty else { return [:] }
        var a: [String: Any] = ["synthetic": true, "synthetic.source": "watchtower", "synthetic.run_id": String(run.prefix(64))]
        if let c = env["WT_SYNTHETIC_CHECK_ID"], !c.isEmpty { a["synthetic.check_id"] = String(c.prefix(64)) }
        return a
    }
}
