import XCTest
@testable import Watchtower

final class WireframeTests: XCTestCase {
    private func node(_ id: Int, _ text: String? = nil, kind: String = "text") -> WireNode {
        WireNode(id: id, x: 0, y: id * 10, w: 50, h: 10, kind: kind, bg: "#ffffff", text: text)
    }

    func testTextIsHiddenByDefaultAndSecureAlways() {
        XCTAssertTrue(hidesText(.text, maskText: true))
        XCTAssertFalse(hidesText(.text, maskText: false))
        XCTAssertFalse(hidesText(.text, maskText: true, unmask: true))
        XCTAssertTrue(hidesText(.input, maskText: true, unmask: true), "unmask never lifts an input")
        XCTAssertTrue(hidesText(.secure, maskText: false, unmask: true))
        XCTAssertTrue(hidesText(.text, maskText: false, forceMask: true))
        XCTAssertEqual(wireText("hunter2", hide: true), "*******")
        XCTAssertEqual(wireText("hello", hide: false), "hello")
        XCTAssertEqual(wireText(String(repeating: "a", count: 500), hide: false).count, 200)
        XCTAssertEqual(wireText(String(repeating: "a", count: 500), hide: true).count, 64)
    }

    func testFullThenDiffThenNothing() {
        let e = WireframeEncoder()
        e.keyEvery = 3
        let a = [node(1), node(2, "**")]
        let f1 = e.encode(nodes: a, w: 100, h: 200, screen: "Home", tsMs: 1)
        let p1 = (f1?["data"] as? [String: Any])?["payload"] as? [String: Any]
        XCTAssertEqual(p1?["full"] as? Bool, true)
        XCTAssertEqual(p1?["masked"] as? Bool, true)
        XCTAssertEqual((p1?["nodes"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(((f1?["data"] as? [String: Any])?["tag"]) as? String, "wt.wireframe")

        XCTAssertNil(e.encode(nodes: a, w: 100, h: 200, screen: "Home", tsMs: 2), "no change, nothing sent")

        let b = [node(1), node(2, "***")]
        let p2 = ((e.encode(nodes: b, w: 100, h: 200, screen: "Home", tsMs: 3)?["data"] as? [String: Any])?["payload"]) as? [String: Any]
        XCTAssertEqual(p2?["full"] as? Bool, false)
        XCTAssertEqual((p2?["nodes"] as? [[String: Any]])?.map { $0["id"] as? Int }, [2])
        XCTAssertEqual(p2?["order"] as? [Int], [1, 2])
    }

    func testRemovedViewChangesTheOrderOnly() {
        let e = WireframeEncoder()
        _ = e.encode(nodes: [node(1), node(2)], w: 1, h: 1, screen: "S", tsMs: 1)
        let p = ((e.encode(nodes: [node(1)], w: 1, h: 1, screen: "S", tsMs: 2)?["data"] as? [String: Any])?["payload"]) as? [String: Any]
        XCTAssertEqual(p?["order"] as? [Int], [1])
        XCTAssertEqual((p?["nodes"] as? [[String: Any]])?.count, 0)
    }

    func testNodeJsonKeepsOnlyWhatTheServerKnows() {
        let j = WireframeEncoder.json(node(5, "x", kind: "input"))
        XCTAssertEqual(Set(j.keys), ["id", "x", "y", "w", "h", "k", "bg", "t"])
    }
}
