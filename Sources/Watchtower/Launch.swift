import Foundation

/// App launch timing (RUM-010): one `app_launch_cold` or `app_launch_warm` vital per start, value =
/// total milliseconds to the first frame, with the phase breakdown as attributes. Pure: the
/// notifications in `Instrument` feed it marks (seconds since 1970), so it is unit tested.
///
/// Cold phases: process (process start to SDK start; pre-main and early app code), application
/// (SDK start to `didFinishLaunching`), ui (to `didBecomeActive`), first_frame (to the first display
/// link tick). A prewarmed launch (iOS 15+, `ActivePrewarm=1`) starts at the SDK, since the process
/// may have been created long before the user tapped. Warm: back from the background, from
/// `willEnterForeground` through `didBecomeActive` to the first frame.
public final class LaunchTracker {
    private let processStart: Double
    private let sdkStart: Double
    private let prewarmed: Bool
    private var finished: Double?
    private var foreground: Double?
    private var active: Double?
    private var coldDone = false

    public init(processStart: Double, sdkStart: Double, prewarmed: Bool) {
        self.processStart = processStart; self.sdkStart = sdkStart; self.prewarmed = prewarmed
    }

    public func didFinishLaunching(_ t: Double) { if finished == nil { finished = t } }
    public func willEnterForeground(_ t: Double) { if coldDone { foreground = t; active = nil } }
    public func didBecomeActive(_ t: Double) { if active == nil { active = t } }

    /// The first frame after becoming active; returns the launch event once per launch.
    public func firstFrame(_ t: Double, screen: String = "") -> Event? {
        let ms = { (a: Double, b: Double) in max(0, (b - a) * 1000).rounded() }
        guard let act = active else { return nil }
        active = nil
        if !coldDone {
            coldDone = true
            let start = prewarmed ? sdkStart : processStart
            let fin = finished ?? act
            return Event(type: "vital", name: "app_launch_cold", value: ms(start, t), attrs: [
                "launch.type": "cold", "launch.prewarmed": prewarmed, "screen": screen,
                "launch.phase.process_ms": prewarmed ? 0 : ms(processStart, sdkStart),
                "launch.phase.application_ms": ms(sdkStart, fin),
                "launch.phase.ui_ms": ms(fin, act),
                "launch.phase.first_frame_ms": ms(act, t),
            ])
        }
        guard let fg = foreground else { return nil } // active again without leaving (alerts, control center)
        foreground = nil
        return Event(type: "vital", name: "app_launch_warm", value: ms(fg, t), attrs: [
            "launch.type": "warm", "screen": screen,
            "launch.phase.ui_ms": ms(fg, act),
            "launch.phase.first_frame_ms": ms(act, t),
        ])
    }
}
