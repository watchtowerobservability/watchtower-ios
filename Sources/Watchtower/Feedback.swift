import Foundation

/// The `POST /v1/rum/feedback` body (ERR-014), like the browser SDK's `feedbackBody`: the message
/// trimmed and cut to 4096 characters, name and email to 256, and `event_id` only when it is 32
/// hex characters once the dashes of an event UUID are gone. Nil without a message.
public func feedbackBody(message: String, name: String?, email: String?, eventId: String?) -> [String: String]? {
    let trim = { (s: String?, max: Int) in String((s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(max)) }
    let m = trim(message, 4096)
    guard !m.isEmpty else { return nil }
    var b = ["message": m]
    let id = (eventId ?? "").replacingOccurrences(of: "-", with: "").lowercased()
    if id.count == 32, id.allSatisfy({ "0123456789abcdef".contains($0) }) { b["event_id"] = id }
    if !trim(name, 256).isEmpty { b["name"] = trim(name, 256) }
    if !trim(email, 256).isEmpty { b["email"] = trim(email, 256) }
    return b
}
