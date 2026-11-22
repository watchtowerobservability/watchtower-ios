import XCTest
@testable import Watchtower

/// UPT-006: a check run's launch environment tags the session as that run.
final class SyntheticTests: XCTestCase {
    func testRunIdFromTheLaunchEnvironment() {
        let a = Synthetic.from(["WT_SYNTHETIC_RUN_ID": "0123abcd", "WT_SYNTHETIC_CHECK_ID": "mon_1"])
        XCTAssertEqual(a["synthetic.run_id"] as? String, "0123abcd")
        XCTAssertEqual(a["synthetic.check_id"] as? String, "mon_1")
        XCTAssertEqual(a["synthetic"] as? Bool, true)
        XCTAssertTrue(Synthetic.from([:]).isEmpty)
        XCTAssertTrue(Synthetic.from(["WT_SYNTHETIC_RUN_ID": ""]).isEmpty)
    }
}
