import Foundation

/// One view of a wireframe: its box, colour and (already masked) text. No pixels, so a frame is a
/// few KB, and nothing leaves the device that the masking rules did not clear.
public struct WireNode: Equatable {
    public var id: Int
    public var x, y, w, h: Int
    /// `view`, `text`, `input` or `image` (a placeholder box).
    public var kind: String
    /// `#rrggbb`.
    public var bg: String?
    public var text: String?
    public init(id: Int, x: Int, y: Int, w: Int, h: Int, kind: String, bg: String? = nil, text: String? = nil) {
        self.id = id; self.x = x; self.y = y; self.w = w; self.h = h; self.kind = kind; self.bg = bg; self.text = text
    }
}

/// The same rule `maskRects` applies to pixels, applied to text: default (`maskText`) hides all
/// text and inputs, secure fields and `wt-mask` views always, `wt-unmask` lifts a text view only.
public func hidesText(_ kind: Kind, maskText: Bool, unmask: Bool = false, forceMask: Bool = false) -> Bool {
    forceMask || kind == .secure
        || (kind == .input && (maskText || !unmask))
        || (kind == .text && maskText && !unmask)
}

/// Text as it may leave the device: cut to 200 characters; hidden text becomes `*` of the same
/// length (at most 64) so the layout keeps its shape.
public func wireText(_ s: String, hide: Bool) -> String {
    let t = String(s.prefix(200))
    return hide ? String(repeating: "*", count: min(t.count, 64)) : t
}

public func wireKind(_ k: Kind) -> String {
    switch k {
    case .text: return "text"
    case .input, .secure: return "input"
    case .image: return "image"
    case .other: return "view"
    }
}

/// Turns successive node lists into `wt.wireframe` rrweb custom events: a full snapshot first and
/// every `keyEvery` frames, otherwise only the changed nodes plus the paint order. A frame with
/// no change is not sent.
public final class WireframeEncoder {
    private var prev: [Int: WireNode] = [:]
    private var prevOrder: [Int] = []
    private var count = 0
    public var keyEvery = 10
    public init() {}

    public func encode(nodes: [WireNode], w: Int, h: Int, screen: String, tsMs: Int64) -> [String: Any]? {
        let full = count % max(1, keyEvery) == 0
        let order = nodes.map { $0.id }
        let changed = full ? nodes : nodes.filter { prev[$0.id] != $0 }
        if !full && changed.isEmpty && order == prevOrder { return nil }
        count += 1
        prev = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, n in n })
        prevOrder = order
        let payload: [String: Any] = ["masked": true, "full": full, "w": w, "h": h, "screen": screen,
                                      "order": order, "nodes": changed.map(Self.json)]
        return ["type": 5, "timestamp": tsMs, "data": ["tag": "wt.wireframe", "payload": payload] as [String: Any]]
    }

    static func json(_ n: WireNode) -> [String: Any] {
        var o: [String: Any] = ["id": n.id, "x": n.x, "y": n.y, "w": n.w, "h": n.h, "k": n.kind]
        if let b = n.bg { o["bg"] = b }
        if let t = n.text { o["t"] = t }
        return o
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// The UIKit view tree (and the accessibility tree of SwiftUI hosting views) as wire nodes.
enum WireframeCapture {
    static let maxNodes = 1500

    static func hex(_ c: UIColor?) -> String? {
        guard let c else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a), a > 0.01 else { return nil }
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    static func text(_ v: UIView) -> String? {
        switch v {
        case let l as UILabel: return l.text
        case let b as UIButton: return b.title(for: .normal)
        case let t as UITextField: return t.text
        case let t as UITextView: return t.text
        default: return nil
        }
    }

    static func nodes(_ root: UIView, _ c: ReplayConfig) -> [WireNode] {
        var out: [WireNode] = []
        func box(_ r: CGRect) -> (Int, Int, Int, Int) { (Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)) }
        func visit(_ v: UIView) {
            guard out.count < maxNodes, !v.isHidden, v.alpha > 0.01 else { return }
            let (x, y, w, h) = box(v.convert(v.bounds, to: root))
            let tag = v.accessibilityIdentifier
            let force = tag == "wt-mask", unmask = tag == "wt-unmask"
            let k = Replay.kind(v)
            let hide = hidesText(k, maskText: c.maskText, unmask: unmask, forceMask: force)
            out.append(WireNode(id: ObjectIdentifier(v).hashValue, x: x, y: y, w: w, h: h, kind: wireKind(k),
                                bg: hex(v.backgroundColor), text: text(v).map { wireText($0, hide: hide) }))
            if force { return } // a hidden container shows no children
            if String(describing: type(of: v)).contains("HostingView") { accessibility(v, root, c, &out) }
            v.subviews.forEach(visit)
        }
        visit(root)
        return out
    }

    /// SwiftUI draws its own content, so its hosting view has no UIKit children: the accessibility
    /// elements (label, frame, traits) stand in for them. Text is masked like a UILabel's.
    private static func accessibility(_ host: UIView, _ root: UIView, _ c: ReplayConfig, _ out: inout [WireNode]) {
        var stack: [NSObject] = (host.accessibilityElements as? [NSObject]) ?? []
        var seen = 0
        while let e = stack.popLast(), seen < 400, out.count < maxNodes {
            seen += 1
            let n = e.accessibilityElementCount()
            if n != NSNotFound && n > 0 {
                for i in 0..<min(n, 100) { if let child = e.accessibilityElement(at: i) as? NSObject { stack.append(child) } }
            }
            let f = root.convert(e.accessibilityFrame, from: nil)
            guard f.width > 0, f.height > 0 else { continue }
            let traits = e.accessibilityTraits
            let k: Kind = traits.contains(.image) ? .image
                : (e.accessibilityValue != nil && !traits.contains(.staticText) && !traits.contains(.button)) ? .input : .text
            let label = e.accessibilityLabel
            let hide = hidesText(k, maskText: c.maskText)
            var hasher = Hasher()
            hasher.combine(Int(f.minX)); hasher.combine(Int(f.minY)); hasher.combine(Int(f.width)); hasher.combine(label)
            out.append(WireNode(id: hasher.finalize(), x: Int(f.minX), y: Int(f.minY), w: Int(f.width), h: Int(f.height),
                                kind: wireKind(k), text: k == .image ? nil : label.map { wireText($0, hide: hide) }))
        }
    }
}
#endif
