import Darwin
import RufCore
import XCTest

@testable import Ruf

final class ApplicationProcessTreeSamplerTests: XCTestCase {
    func testTraversesAnUnreadableIntermediateProcess() throws {
        let rootPID: pid_t = 10
        let unreadablePID: pid_t = 20
        let descendantPID: pid_t = 30
        let rootCounters = ProcessResourceCounters(
            identity: ProcessResourceIdentity(pid: rootPID, startTime: 1),
            capturedAt: 500,
            cumulativeCPUTime: 100,
            physicalFootprintBytes: 1_000
        )
        let descendantCounters = ProcessResourceCounters(
            identity: ProcessResourceIdentity(
                pid: descendantPID,
                startTime: 2
            ),
            capturedAt: 500,
            cumulativeCPUTime: 200,
            physicalFootprintBytes: 2_000
        )
        let query = ApplicationProcessTreeSampler.Query(
            capturedAt: { 500 },
            processCounters: { processIdentifier in
                switch processIdentifier {
                case rootPID:
                    .success(rootCounters)
                case unreadablePID:
                    .unavailable
                case descendantPID:
                    .success(descendantCounters)
                default:
                    .disappeared
                }
            },
            childPIDs: { processIdentifier in
                switch processIdentifier {
                case rootPID:
                    .success([unreadablePID])
                case unreadablePID:
                    .success([descendantPID])
                case descendantPID:
                    .success([])
                default:
                    .disappeared
                }
            }
        )

        let snapshot = try XCTUnwrap(
            ApplicationProcessTreeSampler(query: query).snapshot(
                for: rootPID
            )
        )

        XCTAssertEqual(snapshot.capturedAt, 500)
        XCTAssertEqual(snapshot.rootIdentity, rootCounters.identity)
        XCTAssertEqual(
            snapshot.processes,
            [rootCounters, descendantCounters]
        )
        XCTAssertEqual(snapshot.physicalFootprintBytes, 3_000)
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

    func testUnavailableRootDoesNotReturnAPartialSnapshot() {
        XCTAssertNil(
            ApplicationProcessTreeSampler().snapshot(for: Int32.max)
        )
    }
}
