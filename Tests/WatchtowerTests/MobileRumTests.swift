import XCTest
@testable import Watchtower

final class MobileRumTests: XCTestCase {
    private func state(fg: Bool = true) -> RunState {
        var r = RunState(session: "s1", last: 50, appVersion: "1.0+1", osVersion: "17.4", bootTime: 10)
        r.foreground = fg
        return r
    }

    func testUnexplainedTerminationIsOomInForegroundAndWatchdogInBackground() {
        let now = state()
        XCTAssertEqual(SessionEnd.reason(previous: state(), now: now, crashReport: false), "oom")
        XCTAssertEqual(SessionEnd.reason(previous: state(fg: false), now: now, crashReport: false), "watchdog")
        var hung = state(); hung.hanging = true
        XCTAssertEqual(SessionEnd.reason(previous: hung, now: now, crashReport: false), "watchdog")
        XCTAssertEqual(SessionEnd.errorFor("oom", state())?.attrs["crash.class"] as? String, "oom")
        XCTAssertEqual(SessionEnd.errorFor("watchdog", hung)?.name, "WatchdogTermination")
        XCTAssertNil(SessionEnd.errorFor("watchdog", state(fg: false)), "background kills include force-quits")
    }

    func testCrashUpgradeRebootAndCleanExitAreNotOom() {
        let now = state()
        XCTAssertEqual(SessionEnd.reason(previous: state(), now: now, crashReport: true), "crash")
        var ex = state(); ex.crashed = true
        XCTAssertEqual(SessionEnd.reason(previous: ex, now: now, crashReport: false), "crash")
        var clean = state(); clean.cleanExit = true
        XCTAssertEqual(SessionEnd.reason(previous: clean, now: now, crashReport: false), "user_exit")
        var upgraded = now; upgraded.appVersion = "1.1+2"
        XCTAssertEqual(SessionEnd.reason(previous: state(), now: upgraded, crashReport: false), "user_exit")
        var rebooted = now; rebooted.bootTime = 900
        XCTAssertEqual(SessionEnd.reason(previous: state(fg: false), now: rebooted, crashReport: false), "background_timeout")
        let end = SessionEnd.endEvent("oom", state()).json()
        XCTAssertEqual(end["type"] as? String, "action")
        XCTAssertEqual((end["attrs"] as? [String: Any])?["session.end_reason"] as? String, "oom")
        XCTAssertEqual(end["ts_ns"] as? Int64, 50_000_000_000)
    }

    func testRunStateSurvivesTheNextLaunch() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(Run.start(dir, state()))
        Run.update { $0.hanging = true }
        let prev = Run.start(dir, state())
        XCTAssertEqual(prev?.session, "s1")
        XCTAssertEqual(prev?.hanging, true)
        try? FileManager.default.removeItem(at: dir)
    }

    func testResourceUrlLosesQueryAndCarriesSpan() {
        XCTAssertEqual(Network.scrubUrl("https://api.example/a?token=x#y"), "https://api.example/a")
        let e = Network.resourceEvent(url: "https://api.example/a?q=1", method: "post", status: 503, durationMs: 12.4,
                                      bytes: 10, start: Date(timeIntervalSince1970: 1), ids: (String(repeating: "a", count: 32), "b1b2b3b4b5b6b7b8"))
        let j = e.json()
        XCTAssertEqual(j["type"] as? String, "resource")
        XCTAssertEqual(j["value"] as? Double, 12)
        XCTAssertEqual(j["span_id"] as? String, "b1b2b3b4b5b6b7b8")
        let a = j["attrs"] as? [String: Any]
        XCTAssertEqual(a?["url"] as? String, "https://api.example/a")
        XCTAssertEqual(a?["method"] as? String, "POST")
        XCTAssertEqual(a?["failed"] as? Bool, true)
    }

    func testTraceparentOnlyToAllowedHostsNeverTheEdge() {
        var c = Config(key: "k", service: "shop")
        c.endpoint = "https://edge.example"
        c.propagateTo = ["https://api.example/"]
        XCTAssertTrue(Network.shouldPropagate("https://api.example/v1/cart", c))
        XCTAssertFalse(Network.shouldPropagate("https://cdn.other/x.js", c))
        c.propagateTo = ["https://"]
        XCTAssertFalse(Network.shouldPropagate("https://edge.example/v1/rum/events", c))
        let (t, s) = (Network.hex(16), Network.hex(8))
        let parsed = Network.parseTraceparent(Network.traceparent(t, s))
        XCTAssertEqual(parsed?.0, t)
        XCTAssertEqual(parsed?.1, s)
        XCTAssertNil(Network.parseTraceparent("00-zz-yy-01"))
    }

    func testViewsCarryRouteUrlAndTimeSpentOnThePreviousScreen() {
        let v = ViewTracker(service: "shop")
        let first = v.appeared("HomeViewController", at: 1)
        XCTAssertEqual(first?.type, "view")
        XCTAssertEqual(first?.attrs["url"] as? String, "app://shop/HomeViewController")
        XCTAssertNil(first?.attrs["previous_route"])
        XCTAssertNil(v.appeared("HomeViewController", at: 1.1), "same screen again is not a new view")
        v.disappeared("HomeViewController", at: 3)
        let next = v.appeared("CartViewController", at: 3.05)
        XCTAssertEqual(next?.attrs["previous_route"] as? String, "HomeViewController")
        XCTAssertEqual(next?.attrs["previous_duration_ms"] as? Double, 2000)
        XCTAssertEqual(v.current, "CartViewController")
    }

    func testLaunchCrashesCountUntilARunSurvivesTheWindow() {
        var p = state(); p.launchedAt = 48; p.crashed = true // crashed 2 s after start
        XCTAssertEqual(CrashLoop.count(previous: p, crashed: true), 1)
        p.launchCrashes = 2
        XCTAssertEqual(CrashLoop.count(previous: p, crashed: true), 3)
        XCTAssertEqual(CrashLoop.count(previous: p, crashed: false), 0, "a run that did not crash resets")
        p.launchedAt = 40 // crashed 10 s in: past the window
        XCTAssertEqual(CrashLoop.count(previous: p, crashed: true), 0)
        XCTAssertEqual(CrashLoop.count(previous: state(), crashed: true), 0, "older state without launchedAt")
        XCTAssertEqual(CrashLoop.count(previous: nil, crashed: true), 0)
    }

    func testLaunchCrashTagsOnlyInsideTheWindow() {
        let a = CrashLoop.attrs(sinceLaunch: 1.234, loopCount: 2)
        XCTAssertEqual(a["crash.launch"] as? Bool, true)
        XCTAssertEqual(a["crash.since_launch_ms"] as? Int, 1234)
        XCTAssertEqual(a["crash.loop_count"] as? Int, 2)
        XCTAssertTrue(CrashLoop.attrs(sinceLaunch: 5, loopCount: 1).isEmpty)
    }

    func testFeedbackBodyTrimsCutsAndLinksOnlyAValidEventId() {
        let b = feedbackBody(message: "  broken  ", name: " Ann ", email: "", eventId: "0A1B2C3D-0000-4000-8000-00000000000F")
        XCTAssertEqual(b, ["message": "broken", "name": "Ann", "event_id": "0a1b2c3d00004000800000000000000f"])
        XCTAssertNil(feedbackBody(message: "   ", name: nil, email: nil, eventId: nil))
        XCTAssertNil(feedbackBody(message: "x", name: nil, email: nil, eventId: "nope")?["event_id"])
        XCTAssertEqual(feedbackBody(message: String(repeating: "a", count: 5000), name: nil, email: nil, eventId: nil)?["message"]?.count, 4096)
    }

    func testRequestsCarryTheBundleIdForTheEdgeAppIdCheck() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let t = Transport(cfg: Config(key: "wtp_k", service: "s"), buffer: OfflineBuffer(dir: dir, maxBytes: 1 << 10),
                          session: "s1", device: [:])
        let r = t.request("/v1/rum/events", body: Data())
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Authorization"), "Bearer wtp_k")
        XCTAssertEqual(r?.value(forHTTPHeaderField: "X-Watchtower-App-Id"), Bundle.main.bundleIdentifier)
        XCTAssertNil(r?.value(forHTTPHeaderField: "Origin"))
    }
}
