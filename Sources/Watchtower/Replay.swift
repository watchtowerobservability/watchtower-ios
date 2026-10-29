import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Screenshot replay. Every frame is masked on the device before it is encoded: labels and inputs
/// are painted over by default, secure fields always, and the frame is marked `masked` only after
/// that painting. The edge drops the image of any frame that is not marked masked.
enum Replay {
    private static var timer: Timer?

    static func install(_ c: ReplayConfig, _ wt: Watchtower) {
        DispatchQueue.main.async {
            timer = Timer.scheduledTimer(withTimeInterval: c.interval, repeats: true) { _ in
                guard let w = UIApplication.shared.windows.first(where: { $0.isKeyWindow }),
                      let ev = capture(w, c) else { return }
                wt.postReplay([ev])
            }
        }
    }

    private static func kind(_ v: UIView) -> Kind {
        if let t = v as? UITextField { return t.isSecureTextEntry ? .secure : .input }
        if let t = v as? UITextView { return t.isSecureTextEntry ? .secure : .input }
        if v is UILabel || v is UIButton { return .text }
        if v is UIImageView { return .image }
        return .other
    }

    private static func tree(_ v: UIView, in root: UIView) -> Node {
        let f = v.convert(v.bounds, to: root)
        let kids = v.subviews.filter { !$0.isHidden && $0.alpha > 0 }.map { tree($0, in: root) }
        let tag = v.accessibilityIdentifier
        return Node(kind(v), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height),
                    unmask: tag == "wt-unmask", forceMask: tag == "wt-mask", children: kids)
    }

    static func capture(_ root: UIView, _ c: ReplayConfig) -> [String: Any]? {
        guard root.bounds.width > 0, root.bounds.height > 0 else { return nil }
        let rects = maskRects(tree(root, in: root), maskText: c.maskText)
        let scale = min(1, c.maxSide / max(root.bounds.width, root.bounds.height))
        let size = CGSize(width: max(1, root.bounds.width * scale), height: max(1, root.bounds.height * scale))
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            ctx.cgContext.scaleBy(x: scale, y: scale)
            root.drawHierarchy(in: root.bounds, afterScreenUpdates: false)
            UIColor.darkGray.setFill()
            rects.forEach { ctx.fill(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)) }
        }
        guard let jpg = img.jpegData(compressionQuality: c.jpegQuality) else { return nil }
        return screenshotEvent(tsMs: Int64(Date().timeIntervalSince1970 * 1000), imageB64: jpg.base64EncodedString(),
                               w: Int(size.width), h: Int(size.height), screen: String(describing: type(of: root)),
                               masks: rects.count, masked: true)
    }
}
#else
enum Replay {
    static func install(_ c: ReplayConfig, _ wt: Watchtower) {}
}
#endif
