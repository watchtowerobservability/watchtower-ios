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
}
