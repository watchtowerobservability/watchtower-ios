import Foundation

public let defaultEndpoint = "https://edge.watchtower.local" // placeholder; set `endpoint`
public let sdkName = "watchtower.ios"
public let sdkVersion = "0.1.0"

/// Replay options. Text and inputs are masked unless the app opts out per view or turns masking off.
public struct ReplayConfig {
    public var enabled = false
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
    /// Last chance to edit or drop (return nil) an event before it is buffered.
    public var redact: (Event) -> Event? = { $0 }
    public init(key: String, service: String) { self.key = key; self.service = service }
}
