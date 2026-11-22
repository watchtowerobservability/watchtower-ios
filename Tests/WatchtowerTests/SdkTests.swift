import XCTest
@testable import Watchtower

final class SdkTests: XCTestCase {
    private func tree(_ kids: Node...) -> Node { Node(.other, 0, 0, 100, 200, children: kids) }

    func testReplayMasksTextAndInputsByDefault() {
        let r = maskRects(tree(Node(.text, 0, 0, 50, 10), Node(.input, 0, 20, 50, 10), Node(.image, 0, 40, 50, 10)))
        XCTAssertEqual(r, [MaskRect(x: 0, y: 0, w: 50, h: 10), MaskRect(x: 0, y: 20, w: 50, h: 10)])
    }

    func testUnmaskNeverLiftsInputsOrSecureFields() {
        let r = maskRects(tree(Node(.text, 0, 0, 5, 5, unmask: true), Node(.input, 0, 10, 5, 5, unmask: true),
                               Node(.secure, 0, 20, 5, 5, unmask: true)))
        XCTAssertEqual(r, [MaskRect(x: 0, y: 10, w: 5, h: 5), MaskRect(x: 0, y: 20, w: 5, h: 5)])
    }

    func testSecureStaysMaskedWhenTextMaskingIsOff() {
        let r = maskRects(tree(Node(.text, 0, 0, 5, 5), Node(.secure, 0, 10, 5, 5)), maskText: false)
        XCTAssertEqual(r, [MaskRect(x: 0, y: 10, w: 5, h: 5)])
    }

    func testAppAttributesCannotUseTheWtNamespace() {
        let a = safeAttrs(["wt.project_id": "x", "screen": "Home"])
        XCTAssertNil(a["wt.project_id"])
        XCTAssertNotNil(a["screen"])
    }

    func testOfflineBufferDropsOldestPastItsLimit() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let b = OfflineBuffer(dir: dir, maxBytes: 25)
        for _ in 0..<5 { b.add(Data("0123456789".utf8)) }
        XCTAssertEqual(b.count, 2)
        try? FileManager.default.removeItem(at: dir)
    }

    func testScreenshotEventCarriesMaskedFlag() {
        let e = screenshotEvent(tsMs: 1, imageB64: "AA", w: 1, h: 1, screen: "Home", masks: 2, masked: true)
        let p = ((e["data"] as? [String: Any])?["payload"]) as? [String: Any]
        XCTAssertEqual(e["type"] as? Int, 5)
        XCTAssertEqual(p?["masked"] as? Bool, true)
    }

    func testColdLaunchPhasesThenWarmFromBackground() {
        let l = LaunchTracker(processStart: 100.0, sdkStart: 100.2, prewarmed: false)
        l.didFinishLaunching(100.5); l.didBecomeActive(100.6)
        let cold = l.firstFrame(100.7)
        XCTAssertEqual(cold?.name, "app_launch_cold")
        XCTAssertEqual(cold?.value, 700)
        XCTAssertEqual(cold?.attrs["launch.phase.process_ms"] as? Double, 200)
        XCTAssertEqual(cold?.attrs["launch.phase.application_ms"] as? Double, 300)
        XCTAssertEqual(cold?.attrs["launch.phase.first_frame_ms"] as? Double, 100)
        XCTAssertNil(l.firstFrame(100.8))
        // active again without going to the background is not a launch
        l.didBecomeActive(101); XCTAssertNil(l.firstFrame(101.1))
        l.willEnterForeground(200); l.didBecomeActive(200.05)
        let warm = l.firstFrame(200.1)
        XCTAssertEqual(warm?.name, "app_launch_warm")
        XCTAssertEqual(warm?.value, 100)
    }

    func testPrewarmedLaunchStartsAtTheSdk() {
        let l = LaunchTracker(processStart: 0, sdkStart: 50, prewarmed: true)
        l.didFinishLaunching(50.1); l.didBecomeActive(50.2)
        XCTAssertEqual(l.firstFrame(50.3)?.value, 300)
    }

    func testSignalReportIsWrittenWithoutAllocationAndSentNextLaunch() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        CrashReport.install(dir)
        CrashReport.writeReport(SIGSEGV)
        let e = CrashReport.collect(dir)
        XCTAssertEqual(e?.name, "signal 11")
        XCTAssertEqual(e?.attrs["crash.class"] as? String, "signal")
        XCTAssertTrue((e?.attrs["error.stack"] as? String ?? "").hasPrefix("0x"))
        XCTAssertTrue((e?.attrs["crash.image_base"] as? String ?? "").hasPrefix("0x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CrashReport.file(dir).path), "sent once")
    }

    func testTruncatedOrForeignReportIsIgnored() {
        XCTAssertNil(CrashReport.parse(""))
        XCTAssertNil(CrashReport.parse("wt-crash v1\nsignal x\n"))
        XCTAssertEqual(CrashReport.parse("wt-crash v1\nsignal 6\nbase 0x1\n")?.name, "signal 6")
    }
}

final class ErrorLinkTests: XCTestCase {
    func testErrorsCarryBuildIdAndReplaySession() {
        var c = Config(key: "k", service: "s")
        XCTAssertTrue(Watchtower.errorLinks(c, "s1").isEmpty)
        c.buildId = "dsym-uuid"
        c.replay.enabled = true
        let a = Watchtower.errorLinks(c, "s1")
        XCTAssertEqual(a["debug.build_id"] as? String, "dsym-uuid")
        XCTAssertEqual(a["replay.session_id"] as? String, "s1")
    }
}
