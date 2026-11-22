import XCTest
@testable import Watchtower

final class MetricKitTests: XCTestCase {
    private let tree: [String: Any] = [
        "callStackPerThread": true,
        "callStacks": [
            ["threadAttributed": false, "callStackRootFrames": [
                ["binaryName": "libsystem_kernel.dylib", "address": 1, "offsetIntoBinaryTextSegment": 1, "binaryUUID": "K"],
            ]],
            ["threadAttributed": true, "callStackRootFrames": [
                ["binaryName": "Shop", "address": 0x10_4abc, "offsetIntoBinaryTextSegment": 2748, "binaryUUID": "U1",
                 "subFrames": [["binaryName": "UIKitCore", "address": 0xff, "offsetIntoBinaryTextSegment": 9, "binaryUUID": "U2"]]],
            ]],
        ],
    ]
    private let meta: [String: Any] = ["appVersion": "2.1", "appBuildVersion": "40", "osVersion": "iPhone OS 17.4"]

    private func payload(_ key: String, _ extra: [String: Any]) -> [String: Any] {
        [key: [["callStackTree": tree, "diagnosticMetaData": meta.merging(extra) { _, x in x }]]]
    }

    func testCrashDiagnosticBecomesAPreviousSessionCrash() throws {
        let begin = Date(timeIntervalSince1970: 1_700_000_000)
        let es = MetricKitMap.events(payload("crashDiagnostics", [
            "signal": 11, "exceptionType": 1, "exceptionCode": 0, "terminationReason": "Namespace SIGNAL, Code 0xb",
        ]), begin: begin)
        let e = try XCTUnwrap(es.first)
        XCTAssertEqual(es.count, 1)
        XCTAssertEqual(e.type, "error")
        XCTAssertEqual(e.name, "signal 11")
        XCTAssertEqual(e.tsNs, 1_700_000_000_000_000_000)
        XCTAssertEqual(e.attrs["crash.class"] as? String, "signal")
        XCTAssertEqual(e.attrs["crash.source"] as? String, "metrickit")
        XCTAssertEqual(e.attrs["crash.handled"] as? Bool, false)
        XCTAssertEqual(e.attrs["crash.previous_session"] as? Bool, true)
        XCTAssertEqual(e.attrs["error.message"] as? String, "Namespace SIGNAL, Code 0xb")
        XCTAssertEqual(e.attrs["app.version"] as? String, "2.1")
        XCTAssertEqual(e.attrs["os.version"] as? String, "iPhone OS 17.4")
        XCTAssertEqual(e.attrs["error.stack"] as? String, "Shop 0x104abc (2748) U1\nUIKitCore 0xff (9) U2")
    }

    func testMachCrashWithoutReasonNamesTheException() {
        let e = MetricKitMap.events(payload("crashDiagnostics", ["exceptionType": 6, "exceptionCode": 1]), begin: Date())[0]
        XCTAssertEqual(e.attrs["crash.class"] as? String, "mach")
        XCTAssertEqual(e.attrs["error.message"] as? String, "exception type 6 code 1")
    }

    func testHangAndCpuExceptionCarryTheirDurations() {
        let hang = MetricKitMap.events(payload("hangDiagnostics", ["hangDuration": "4 sec"]), begin: Date())[0]
        XCTAssertEqual(hang.name, "AppHang")
        XCTAssertEqual(hang.attrs["crash.class"] as? String, "anr")
        XCTAssertEqual(hang.attrs["hang.duration_s"] as? Double, 4)
        let cpu = MetricKitMap.events(payload("cpuExceptionDiagnostics", [
            "totalCPUTime": "1,500 ms", "totalSampledTime": "2 min",
        ]), begin: Date())[0]
        XCTAssertEqual(cpu.name, "CPUException")
        XCTAssertEqual(cpu.attrs["crash.class"] as? String, "cpu_exception")
        XCTAssertEqual(cpu.attrs["cpu.total_time_s"] as? Double, 1.5)
        XCTAssertEqual(cpu.attrs["cpu.total_sampled_time_s"] as? Double, 120)
        XCTAssertTrue((cpu.attrs["error.stack"] as? String ?? "").hasPrefix("Shop 0x104abc"))
    }

    func testEmptyPayloadHasNoEvents() {
        XCTAssertTrue(MetricKitMap.events([:], begin: Date()).isEmpty)
        XCTAssertEqual(MetricKitMap.stack([:]), "")
    }
}
