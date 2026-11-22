import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Automatic screen views (RUM-010), in the browser SDK's `view` shape: name and `route` = the
/// screen, `url` = `app://<service>/<screen>`, and `previous_route` / `previous_duration_ms` (time
/// spent on the screen before). Pure: the swizzled `viewDidAppear` / `viewDidDisappear` feed it.
public final class ViewTracker {
    private let service: String
    private let lock = NSLock()
    private var shown: String?
    private var since: Double = 0
    private var previous: String?
    private var previousMs: Double?

    public init(service: String) { self.service = service }

    /// The screen shown now; frame vitals carry it.
    public var current: String? { lock.lock(); defer { lock.unlock() }; return shown }

    /// `t`: seconds since 1970.
    public func appeared(_ name: String, at t: Double) -> Event? {
        lock.lock(); defer { lock.unlock() }
        if name == shown { return nil }
        if let c = shown { previous = c; previousMs = max(0, (t - since) * 1000).rounded() }
        shown = name
        since = t
        var a: [String: Any] = ["route": name, "url": "app://\(service)/\(name)"]
        if let p = previous { a["previous_route"] = p }
        if let m = previousMs { a["previous_duration_ms"] = m }
        var e = Event(type: "view", name: name, attrs: a)
        e.tsNs = Int64(t * 1e9)
        return e
    }

    public func disappeared(_ name: String, at t: Double) {
        lock.lock(); defer { lock.unlock() }
        guard name == shown else { return }
        previous = name
        previousMs = max(0, (t - since) * 1000).rounded()
        shown = nil
    }
}

#if canImport(UIKit) && !os(watchOS)
enum ViewTracking {
    static var tracker: ViewTracker?

    /// Swaps `viewDidAppear` / `viewDidDisappear` with the recording versions below, once.
    static func install(_ service: String) {
        guard tracker == nil else { return }
        tracker = ViewTracker(service: service)
        swap(#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.wt_viewDidAppear(_:)))
        swap(#selector(UIViewController.viewDidDisappear(_:)), #selector(UIViewController.wt_viewDidDisappear(_:)))
    }

    private static func swap(_ a: Selector, _ b: Selector) {
        guard let m = class_getInstanceMethod(UIViewController.self, a),
              let n = class_getInstanceMethod(UIViewController.self, b) else { return }
        method_exchangeImplementations(m, n)
    }

    /// Containers and the system's own controllers (alerts, keyboards, SwiftUI hosting) are not
    /// screens; the app's controllers count, in the main bundle or the app's own frameworks.
    static func screen(_ vc: UIViewController) -> String? {
        if vc is UINavigationController || vc is UITabBarController || vc is UIPageViewController
            || vc is UISplitViewController { return nil }
        let path = Bundle(for: type(of: vc)).bundlePath
        if path.contains("/System/Library/") || path.hasPrefix("/usr/") { return nil }
        return String(describing: type(of: vc))
    }
}

extension UIViewController {
    @objc func wt_viewDidAppear(_ animated: Bool) {
        wt_viewDidAppear(animated) // the original, after the swap
        if let s = ViewTracking.screen(self),
           let e = ViewTracking.tracker?.appeared(s, at: Date().timeIntervalSince1970) {
            Watchtower.shared.record(e)
        }
    }

    @objc func wt_viewDidDisappear(_ animated: Bool) {
        wt_viewDidDisappear(animated)
        if let s = ViewTracking.screen(self) { ViewTracking.tracker?.disappeared(s, at: Date().timeIntervalSince1970) }
    }
}
#endif
