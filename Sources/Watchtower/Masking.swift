import Foundation

/// What a view is, for masking. Kept apart from UIKit so the rules run in plain unit tests.
public enum Kind { case text, input, secure, image, other }

public struct Node {
    public var kind: Kind
    public var x, y, w, h: Int
    /// The app tagged this view `wt-unmask` (opt out) or `wt-mask` (always hide).
    public var unmask = false
    public var forceMask = false
    public var children: [Node] = []
    public init(_ kind: Kind, _ x: Int, _ y: Int, _ w: Int, _ h: Int, unmask: Bool = false, forceMask: Bool = false, children: [Node] = []) {
        self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h
        self.unmask = unmask; self.forceMask = forceMask; self.children = children
    }
}

public struct MaskRect: Equatable { public var x, y, w, h: Int }

/// Rectangles to paint over before a screenshot leaves the device. Default (`maskText`): all text
/// and all inputs. Secure fields and `wt-mask` views are always masked. `wt-unmask` lifts the mask
/// from a text view only, never from an input or a secure field.
public func maskRects(_ root: Node, maskText: Bool = true) -> [MaskRect] {
    var out: [MaskRect] = []
    func walk(_ n: Node) {
        let hide = n.forceMask || n.kind == .secure
            || (n.kind == .input && (maskText || !n.unmask))
            || (n.kind == .text && maskText && !n.unmask)
        if hide && n.w > 0 && n.h > 0 { out.append(MaskRect(x: n.x, y: n.y, w: n.w, h: n.h)) } else { n.children.forEach(walk) }
    }
    walk(root)
    return out
}

/// The rrweb custom event the edge understands. `masked` is only true after masks were painted.
public func screenshotEvent(tsMs: Int64, imageB64: String, w: Int, h: Int, screen: String, masks: Int, masked: Bool) -> [String: Any] {
    ["type": 5, "timestamp": tsMs,
     "data": ["tag": "wt.screenshot",
              "payload": ["image": imageB64, "mime": "image/jpeg", "w": w, "h": h,
                          "screen": screen, "mask_count": masks, "masked": masked] as [String: Any]] as [String: Any]]
}
