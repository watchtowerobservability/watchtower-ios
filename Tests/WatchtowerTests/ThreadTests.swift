import XCTest
@testable import Watchtower

final class ThreadTests: XCTestCase {
    private let img = ImageInfo(name: "/App.app/App", base: 0x1000, size: 0x1000, vmaddr: 0x1_0000_0000,
                                uuid: "11111111-2222-3333-4444-555555555555")

    func testReportWithThreadsBecomesFramesThreadsAndImages() {
        let text = "wt-crash v1\nsignal 11\nbase 0x1000\nframes\n0x1010\n0x1020\nthread 1\n0x1030\n0x9999\nthread 2\n0x1040\n"
        let e = CrashReport.parse(text, images: [img])
        let frames = e?.attrs["frames"] as? [[String: Any]]
        XCTAssertEqual(frames?.count, 2)
        XCTAssertEqual(frames?.first?["instruction_addr"] as? String, "0x1020", "oldest call first")
        XCTAssertEqual(frames?.first?["debug_id"] as? String, img.uuid)
        XCTAssertEqual(frames?.first?["in_app"] as? Bool, false) // the image is not under this test's bundle
        let threads = e?.attrs["threads"] as? [[String: Any]]
        XCTAssertEqual(threads?.count, 2)
        let t1 = threads?.first?["frames"] as? [[String: Any]]
        XCTAssertEqual(t1?.count, 2)
        XCTAssertNil(t1?.first?["debug_id"], "an address in no image stays absolute")
        let images = e?.attrs["debug_images"] as? [[String: Any]]
        XCTAssertEqual(images?.count, 1)
        XCTAssertEqual(images?.first?["image_addr"] as? String, "0x1000")
        XCTAssertEqual(images?.first?["image_vmaddr"] as? String, "0x100000000")
    }

    func testReportWithoutImagesKeepsTheTextStackOnly() {
        let e = CrashReport.parse("wt-crash v1\nsignal 6\nbase 0x1\nframes\n0x10\nthread 1\n0x20\n")
        XCTAssertEqual(e?.attrs["error.stack"] as? String, "0x10")
        XCTAssertNil(e?.attrs["threads"])
    }

    func testThreadsBudgetKeepsTheAttributeUnderTheEdgeLimit() {
        let addrs = (0..<32).map { UInt64(0x1000 + $0) }
        let a = NativeStacks.attrs(stack: nil, threads: Array(repeating: addrs, count: 24), images: [img])
        let n = (try? JSONSerialization.data(withJSONObject: a["threads"] ?? []).count) ?? Int.max
        XCTAssertLessThanOrEqual(n, 32_768)
    }

    func testSnapshotSeesAnotherThread() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let t = Thread { started.signal(); release.wait() }
        t.start()
        started.wait()
        let snap = ThreadWalker.snapshot()
        release.signal()
        XCTAssertTrue(snap.threads.contains { !$0.isEmpty })
    }

    func testLoadedImagesIncludeOneWithAUuid() {
        XCTAssertTrue(Images.loaded().contains { !$0.uuid.isEmpty && $0.size > 0 })
    }

    func testTrackedImagesIncludeTheLoadedOnesAndTrackOnce() {
        Images.track {} // dyld calls back for every loaded image before this returns
        XCTAssertTrue(Images.loaded().contains { !$0.uuid.isEmpty })
        Images.track {} // a second call only swaps the callback
        XCTAssertEqual(Images.loaded().count, Set(Images.loaded().map { $0.base }).count, "no duplicates")
    }
}
