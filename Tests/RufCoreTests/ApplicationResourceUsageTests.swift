import XCTest
@testable import RufCore

final class ApplicationResourceUsageTests: XCTestCase {
    func testCPUPercentageUsesOnlyContinuousProcessIdentities() throws {
        let root = ProcessResourceIdentity(pid: 10, startTime: 100)
        let child = ProcessResourceIdentity(pid: 11, startTime: 200)
        let newChild = ProcessResourceIdentity(pid: 12, startTime: 300)
        var baseline = ProcessCPUUsageBaseline()

        XCTAssertNil(
            baseline.update(
                snapshot: ProcessTreeResourceSnapshot(
                    capturedAt: 1_000,
                    rootIdentity: root,
                    processes: [
                        ProcessResourceCounters(
                            identity: root,
                            capturedAt: 1_000,
                            cumulativeCPUTime: 1_000,
                            physicalFootprintBytes: 1_000
                        ),
                        ProcessResourceCounters(
                            identity: child,
                            capturedAt: 1_000,
                            cumulativeCPUTime: 2_000,
                            physicalFootprintBytes: 2_000
                        ),
                    ]
                )
            )
        )

        let percentage = try XCTUnwrap(
            baseline.update(
                snapshot: ProcessTreeResourceSnapshot(
                    capturedAt: 1_500,
                    rootIdentity: root,
                    processes: [
                        ProcessResourceCounters(
                            identity: root,
                            capturedAt: 1_500,
                            cumulativeCPUTime: 1_200,
                            physicalFootprintBytes: 1_500
                        ),
                        ProcessResourceCounters(
                            identity: child,
                            capturedAt: 1_500,
                            cumulativeCPUTime: 2_300,
                            physicalFootprintBytes: 2_500
                        ),
                        ProcessResourceCounters(
                            identity: newChild,
                            capturedAt: 1_500,
                            cumulativeCPUTime: 9_000,
                            physicalFootprintBytes: 3_000
                        ),
                    ]
                )
            )
        )

        XCTAssertEqual(percentage, 100, accuracy: 0.001)
    }

    func testCPUPercentageCanExceedOneHundredPercent() throws {
        let process = ProcessResourceIdentity(pid: 10, startTime: 100)
        var baseline = ProcessCPUUsageBaseline()
        _ = baseline.update(
            snapshot: ProcessTreeResourceSnapshot(
                capturedAt: 1_000,
                rootIdentity: process,
                processes: [
                    ProcessResourceCounters(
                        identity: process,
                        capturedAt: 1_000,
                        cumulativeCPUTime: 1_000,
                        physicalFootprintBytes: 1
                    ),
                ]
            )
        )

        let percentage = try XCTUnwrap(
            baseline.update(
                snapshot: ProcessTreeResourceSnapshot(
                    capturedAt: 1_500,
                    rootIdentity: process,
                    processes: [
                        ProcessResourceCounters(
                            identity: process,
                            capturedAt: 1_500,
                            cumulativeCPUTime: 3_000,
                            physicalFootprintBytes: 1
                        ),
                    ]
                )
            )
        )

        XCTAssertEqual(percentage, 400, accuracy: 0.001)
    }

    func testCPUPercentageCountsAProcessBornInsideTheInterval() throws {
        let root = ProcessResourceIdentity(pid: 10, startTime: 100)
        let newChild = ProcessResourceIdentity(pid: 11, startTime: 1_200)
        var baseline = ProcessCPUUsageBaseline()
        _ = baseline.update(
            snapshot: ProcessTreeResourceSnapshot(
                capturedAt: 1_000,
                rootIdentity: root,
                processes: [
                    ProcessResourceCounters(
                        identity: root,
                        capturedAt: 1_000,
                        cumulativeCPUTime: 1_000,
                        physicalFootprintBytes: 1
                    ),
                ]
            )
        )

        let percentage = try XCTUnwrap(
            baseline.update(
                snapshot: ProcessTreeResourceSnapshot(
                    capturedAt: 1_500,
                    rootIdentity: root,
                    processes: [
                        ProcessResourceCounters(
                            identity: root,
                            capturedAt: 1_500,
                            cumulativeCPUTime: 1_100,
                            physicalFootprintBytes: 1
                        ),
                        ProcessResourceCounters(
                            identity: newChild,
                            capturedAt: 1_500,
                            cumulativeCPUTime: 200,
                            physicalFootprintBytes: 1
                        ),
                    ]
                )
            )
        )

        XCTAssertEqual(percentage, 60, accuracy: 0.001)
    }

    func testCPUPercentageResetsWhenTheRootProcessIdentityChanges() {
        let originalRoot = ProcessResourceIdentity(pid: 10, startTime: 100)
        let replacementRoot = ProcessResourceIdentity(pid: 10, startTime: 900)
        var baseline = ProcessCPUUsageBaseline()
        _ = baseline.update(
            snapshot: ProcessTreeResourceSnapshot(
                capturedAt: 1_000,
                rootIdentity: originalRoot,
                processes: [
                    ProcessResourceCounters(
                        identity: originalRoot,
                        capturedAt: 1_000,
                        cumulativeCPUTime: 500,
                        physicalFootprintBytes: 1
                    ),
                ]
            )
        )

        XCTAssertNil(
            baseline.update(
                snapshot: ProcessTreeResourceSnapshot(
                    capturedAt: 1_500,
                    rootIdentity: replacementRoot,
                    processes: [
                        ProcessResourceCounters(
                            identity: replacementRoot,
                            capturedAt: 1_500,
                            cumulativeCPUTime: 100,
                            physicalFootprintBytes: 1
                        ),
                    ]
                )
            )
        )
    }

    func testCPUPercentageRejectsARegressingCounter() {
        let root = ProcessResourceIdentity(pid: 10, startTime: 100)
        var baseline = ProcessCPUUsageBaseline()
        _ = baseline.update(
            snapshot: ProcessTreeResourceSnapshot(
                capturedAt: 1_000,
                rootIdentity: root,
                processes: [
                    ProcessResourceCounters(
                        identity: root,
                        capturedAt: 1_000,
                        cumulativeCPUTime: 500,
                        physicalFootprintBytes: 1
                    ),
                ]
            )
        )

        XCTAssertNil(
            baseline.update(
                snapshot: ProcessTreeResourceSnapshot(
                    capturedAt: 1_500,
                    rootIdentity: root,
                    processes: [
                        ProcessResourceCounters(
                            identity: root,
                            capturedAt: 1_500,
                            cumulativeCPUTime: 400,
                            physicalFootprintBytes: 1
                        ),
                    ]
                )
            )
        )
    }

    func testCPUPercentageUsesEachProcessReadInterval() throws {
        let root = ProcessResourceIdentity(pid: 10, startTime: 1)
        let child = ProcessResourceIdentity(pid: 11, startTime: 2)
        var baseline = ProcessCPUUsageBaseline()
        _ = baseline.update(snapshot: ProcessTreeResourceSnapshot(
            capturedAt: 1_000,
            rootIdentity: root,
            processes: [
                ProcessResourceCounters(
                    identity: root, capturedAt: 1_000,
                    cumulativeCPUTime: 100, physicalFootprintBytes: 1
                ),
                ProcessResourceCounters(
                    identity: child, capturedAt: 1_020,
                    cumulativeCPUTime: 100, physicalFootprintBytes: 1
                ),
            ]
        ))

        let percentage = try XCTUnwrap(baseline.update(
            snapshot: ProcessTreeResourceSnapshot(
                capturedAt: 1_500,
                rootIdentity: root,
                processes: [
                    ProcessResourceCounters(
                        identity: root, capturedAt: 1_500,
                        cumulativeCPUTime: 600, physicalFootprintBytes: 1
                    ),
                    ProcessResourceCounters(
                        identity: child, capturedAt: 1_700,
                        cumulativeCPUTime: 780, physicalFootprintBytes: 1
                    ),
                ]
            )
        ))

        XCTAssertEqual(percentage, 200, accuracy: 0.001)
    }

    func testFootprintOverflowMakesTheTotalUnavailable() {
        let root = ProcessResourceIdentity(pid: 10, startTime: 1)
        let snapshot = ProcessTreeResourceSnapshot(
            capturedAt: 1_000,
            rootIdentity: root,
            processes: [
                ProcessResourceCounters(
                    identity: root, capturedAt: 1_000,
                    cumulativeCPUTime: 0, physicalFootprintBytes: UInt64.max
                ),
                ProcessResourceCounters(
                    identity: ProcessResourceIdentity(pid: 11, startTime: 2),
                    capturedAt: 1_000,
                    cumulativeCPUTime: 0, physicalFootprintBytes: 1
                ),
            ]
        )

        XCTAssertNil(snapshot.physicalFootprintBytes)
    }

    func testResourceUsageFormattingMatchesTheSwitcherLine() {
        let runningDuration = 4 * 86_400 + 5 * 3_600

        XCTAssertEqual(
            ApplicationResourceUsageFormatter.string(
                cpuPercentage: 24.74,
                memoryBytes: 4_200_000_000,
                runningDuration: TimeInterval(runningDuration)
            ),
            "CPU 24.7% · Memory 4.2 GB · Running 4d 5h"
        )
    }

    func testResourceUsageFormattingKeepsUnavailableValuesExplicit() {
        XCTAssertEqual(
            ApplicationResourceUsageFormatter.string(
                cpuPercentage: nil,
                memoryBytes: nil,
                runningDuration: nil
            ),
            "CPU — · Memory — · Running —"
        )
    }
}
