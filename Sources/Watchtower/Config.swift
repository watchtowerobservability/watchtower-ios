import Foundation

public let defaultEndpoint = "https://edge.watchtower.local" // placeholder; set `endpoint`
public let sdkName = "watchtower.ios"
public let sdkVersion = "0.1.1"

/// What a replay frame holds: a masked screenshot, or the view hierarchy (boxes, colours, masked
/// text, image placeholders; no pixels).
public enum ReplayMode { case screenshot, wireframe }

/// Replay options. Text and inputs are masked unless the app opts out per view or turns masking off.
public struct ReplayConfig {
    public var enabled = false
    public var mode: ReplayMode = .screenshot
    /// Mask every label and input (default). False still masks secure fields and views tagged `wt-mask`.
    public var maskText = true
    public var interval: TimeInterval = 1
    public var maxSide: CGFloat = 480
    public var jpegQuality: CGFloat = 0.3
    public init() {}
}

public struct Config {
    /// Publishable ingest key (sent as a bearer token).
    public var key: String
    public var service: String
    public var endpoint = defaultEndpoint
    public var release: String?
    public var environment: String?
    public var replay = ReplayConfig()
    /// Bytes of events kept on disk while offline; the oldest go first.
    public var offlineMaxBytes = 5 << 20
    public var hangThreshold: TimeInterval = 2
    /// One RUM `view` event per shown view controller (swizzled `viewDidAppear`); false turns it off.
    public var trackViews = true
    /// RUM `resource` events for URLSession requests (a URLProtocol); false turns it off.
    public var trackNetwork = true
    /// URL prefixes that get a W3C `traceparent` header (like the browser SDK's `propagateTo`).
    /// Empty: no header is sent anywhere; the Watchtower edge never gets one.
    public var propagateTo: [String] = []
    /// iOS 14+: crash, hang and CPU-exception diagnostics from MetricKit (delivered on a later
    /// launch, tagged `crash.source: metrickit`); false turns it off.
    public var metricKit = true
    /// `Watchtower.shared.isCrashLooping` is true from this many consecutive launch crashes.
    public var crashLoopThreshold = 2
    /// Sample the main thread every 10 ms until the first frame of a cold launch (`app_launch_profile`); opt-in.
    public var profileLaunch = false
    /// Build id (the dSYM UUID `upload-dsyms.sh` uploads); added to every error as `debug.build_id`.
    public var buildId: String?
    /// Last chance to edit or drop (return nil) an event before it is buffered.
    public var redact: (Event) -> Event? = { $0 }
    public init(key: String, service: String) { self.key = key; self.service = service }
}
