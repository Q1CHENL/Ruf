import Darwin
import Foundation
import RufCore
import XCTest

@testable import Ruf

final class ApplicationProcessTreeSamplerTests: XCTestCase {
    func testSamplesTheApplicationGroupAroundAnUnreadableMember() throws {
        let rootPID: pid_t = 10
        let unreadablePID: pid_t = 20
        let descendantPID: pid_t = 30
        let servicePID: pid_t = 40
        let otherApplicationPID: pid_t = 50
        let counters = Dictionary(
            uniqueKeysWithValues: [
                rootPID, descendantPID, servicePID, otherApplicationPID,
            ].map { processIdentifier in
                (
                    processIdentifier,
                    ProcessResourceCounters(
                        identity: ProcessResourceIdentity(
                            pid: processIdentifier,
                            startTime: 1
                        ),
                        capturedAt: 500,
                        cumulativeCPUTime: 100,
                        physicalFootprintBytes: UInt64(processIdentifier) * 100
                    )
                )
            }
        )
        let query = ApplicationProcessTreeSampler.Query(
            capturedAt: { 500 },
            processRelationships: {
                [
                    ProcessRelationship(
                        pid: rootPID,
                        parentPID: 1,
                        responsiblePID: rootPID
                    ),
                    ProcessRelationship(
                        pid: unreadablePID,
                        parentPID: rootPID,
                        responsiblePID: rootPID
                    ),
                    ProcessRelationship(
                        pid: descendantPID,
                        parentPID: unreadablePID,
                        responsiblePID: descendantPID
                    ),
                    ProcessRelationship(
                        pid: servicePID,
                        parentPID: 1,
                        responsiblePID: rootPID
                    ),
                    ProcessRelationship(
                        pid: otherApplicationPID,
                        parentPID: 1,
                        responsiblePID: otherApplicationPID
                    ),
                ]
            },
            processCounters: { counters[$0] }
        )

        let snapshot = try XCTUnwrap(
            ApplicationProcessTreeSampler(query: query).snapshot(
                for: rootPID
            )
        )

        XCTAssertEqual(snapshot.capturedAt, 500)
        XCTAssertEqual(snapshot.rootIdentity, counters[rootPID]?.identity)
        XCTAssertEqual(
            Set(snapshot.processes.map(\.identity.pid)),
            [rootPID, descendantPID, servicePID]
        )
        XCTAssertEqual(snapshot.physicalFootprintBytes, 8_000)
    }

    func testUnreadableRootDoesNotReturnAPartialSnapshot() {
        let query = ApplicationProcessTreeSampler.Query(
            capturedAt: { 500 },
            processRelationships: {
                [
                    ProcessRelationship(pid: 10, parentPID: 1, responsiblePID: 10),
                    ProcessRelationship(pid: 11, parentPID: 10, responsiblePID: 10),
                ]
            },
            processCounters: { processIdentifier in
                processIdentifier == 10
                    ? nil
                    : ProcessResourceCounters(
                        identity: ProcessResourceIdentity(
                            pid: processIdentifier,
                            startTime: 1
                        ),
                        capturedAt: 500,
                        cumulativeCPUTime: 0,
                        physicalFootprintBytes: 1
                    )
            }
        )

        XCTAssertNil(
            ApplicationProcessTreeSampler(query: query).snapshot(for: 10)
        )
    }

    func testSamplesTheCurrentProcess() throws {
        let processIdentifier = getpid()

        let snapshot = try XCTUnwrap(
            ApplicationProcessTreeSampler().snapshot(
                for: processIdentifier
            )
        )

        XCTAssertEqual(
            snapshot.rootIdentity.pid,
            processIdentifier
        )
        XCTAssertTrue(
            snapshot.processes.contains {
                $0.identity == snapshot.rootIdentity
            }
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(snapshot.physicalFootprintBytes),
            0
        )
        XCTAssertGreaterThan(snapshot.capturedAt, 0)
    }

    func testCountsAChildOfTheSampledProcess() throws {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        let snapshot = try XCTUnwrap(
            ApplicationProcessTreeSampler().snapshot(for: getpid())
        )

        XCTAssertTrue(
            snapshot.processes.contains {
                $0.identity.pid == child.processIdentifier
            }
        )
    }

    func testUnavailableRootDoesNotReturnAPartialSnapshot() {
        XCTAssertNil(
            ApplicationProcessTreeSampler().snapshot(for: Int32.max)
        )
    }
}
