import Foundation
import RufCore
import XCTest

@testable import Ruf

@MainActor
final class ApplicationResourceUsageMonitorTests: XCTestCase {
    func testReusesApplicationSamplerWhenRevisitedWithinSession() async {
        let snapshots = ControlledSnapshotProvider()
        let recorder = ResourceUsageRecorder()
        let monitor = ApplicationResourceUsageMonitor(
            initialSampleInterval: .zero,
            refreshInterval: .zero,
            snapshotProvider: { processIdentifier in
                await snapshots.next(for: processIdentifier)
            },
            onUpdate: { usage in
                recorder.latest = usage
            }
        )

        monitor.select(
            processIdentifier: 101,
            launchDate: Date(timeIntervalSince1970: 1),
            isRunning: { true }
        )
        await snapshots.send(
            snapshot(pid: 101, time: 1_000, cpu: 100, memory: 101),
            to: 101
        )
        await waitForRequestCount(2, pid: 101, snapshots: snapshots)
        await snapshots.send(
            snapshot(pid: 101, time: 2_000, cpu: 200, memory: 202),
            to: 101
        )
        await waitForRequestCount(3, pid: 101, snapshots: snapshots)
        XCTAssertEqual(recorder.latest.cpuPercentage, 10)

        monitor.select(
            processIdentifier: 202,
            launchDate: Date(timeIntervalSince1970: 2),
            isRunning: { true }
        )
        await snapshots.send(
            snapshot(pid: 202, time: 1_000, cpu: 100, memory: 303),
            to: 202
        )
        await waitForRequestCount(2, pid: 202, snapshots: snapshots)
        await snapshots.send(
            snapshot(pid: 202, time: 2_000, cpu: 300, memory: 404),
            to: 202
        )
        await waitForRequestCount(3, pid: 202, snapshots: snapshots)
        XCTAssertEqual(recorder.latest.cpuPercentage, 20)

        await snapshots.send(
            snapshot(pid: 101, time: 3_000, cpu: 1_000, memory: 505),
            to: 101
        )
        await waitForRequestCount(4, pid: 101, snapshots: snapshots)
        XCTAssertEqual(recorder.latest.cpuPercentage, 20)

        monitor.select(
            processIdentifier: 101,
            launchDate: Date(timeIntervalSince1970: 1),
            isRunning: { true }
        )

        XCTAssertEqual(recorder.latest.cpuPercentage, 80)
        XCTAssertEqual(recorder.latest.memoryBytes, 505)

        monitor.stopSession()
        monitor.select(
            processIdentifier: 101,
            launchDate: Date(timeIntervalSince1970: 1),
            isRunning: { true }
        )

        XCTAssertNil(recorder.latest.cpuPercentage)

        monitor.stopSession()
        await snapshots.finish()
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        pid: pid_t,
        snapshots: ControlledSnapshotProvider
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while await snapshots.requestCount(for: pid) < expectedCount {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for resource sampler")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func snapshot(
        pid: pid_t,
        time: UInt64,
        cpu: UInt64,
        memory: UInt64
    ) -> ProcessTreeResourceSnapshot {
        let identity = ProcessResourceIdentity(pid: pid, startTime: 1)
        return ProcessTreeResourceSnapshot(
            capturedAt: time,
            rootIdentity: identity,
            processes: [
                ProcessResourceCounters(
                    identity: identity,
                    capturedAt: time,
                    cumulativeCPUTime: cpu,
                    physicalFootprintBytes: memory
                ),
            ]
        )
    }
}

@MainActor
private final class ResourceUsageRecorder {
    var latest = ApplicationResourceUsage(
        cpuPercentage: nil,
        memoryBytes: nil,
        runningDuration: nil
    )
}

private actor ControlledSnapshotProvider {
    private typealias Continuation = CheckedContinuation<
        ProcessTreeResourceSnapshot?,
        Never
    >

    private var queuedSnapshots:
        [pid_t: [ProcessTreeResourceSnapshot]] = [:]
    private var continuations: [pid_t: [Continuation]] = [:]
    private var requestCounts: [pid_t: Int] = [:]
    private var isFinished = false

    func next(for pid: pid_t) async -> ProcessTreeResourceSnapshot? {
        requestCounts[pid, default: 0] += 1

        if var queued = queuedSnapshots[pid], !queued.isEmpty {
            let snapshot = queued.removeFirst()
            queuedSnapshots[pid] = queued
            return snapshot
        }
        guard !isFinished else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            continuations[pid, default: []].append(continuation)
        }
    }

    func send(_ snapshot: ProcessTreeResourceSnapshot, to pid: pid_t) {
        if var waiting = continuations[pid], !waiting.isEmpty {
            let continuation = waiting.removeFirst()
            continuations[pid] = waiting
            continuation.resume(returning: snapshot)
        } else {
            queuedSnapshots[pid, default: []].append(snapshot)
        }
    }

    func requestCount(for pid: pid_t) -> Int {
        requestCounts[pid, default: 0]
    }

    func finish() {
        isFinished = true
        let waiting = continuations.values.flatMap { $0 }
        continuations.removeAll()
        queuedSnapshots.removeAll()
        for continuation in waiting {
            continuation.resume(returning: nil)
        }
    }
}
