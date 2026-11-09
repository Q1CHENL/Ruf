import Foundation
import RufCore
import Synchronization
import XCTest

@testable import Ruf

@MainActor
final class ApplicationResourceUsageMonitorTests: XCTestCase {
    func testSamplesOnlyTheSelectedApplicationAndReusesItsLastSnapshot() async {
        let snapshots = ControlledSnapshotProvider()
        let recorder = ResourceUsageRecorder()
        let monitor = ApplicationResourceUsageMonitor(
            initialSampleInterval: .zero,
            refreshInterval: .zero,
            launchDateProvider: { _ in
                XCTFail("Known launch dates should not query the kernel")
                return nil
            },
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
        snapshots.send(
            snapshot(pid: 101, time: 1_000, cpu: 100, memory: 101),
            to: 101
        )
        await waitForRequestCount(2, pid: 101, snapshots: snapshots)
        snapshots.send(
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
        XCTAssertNil(recorder.latest.cpuPercentage)
        snapshots.send(
            snapshot(pid: 202, time: 1_000, cpu: 100, memory: 303),
            to: 202
        )
        await waitForRequestCount(2, pid: 202, snapshots: snapshots)
        snapshots.send(
            snapshot(pid: 202, time: 2_000, cpu: 300, memory: 404),
            to: 202
        )
        await waitForRequestCount(3, pid: 202, snapshots: snapshots)
        XCTAssertEqual(recorder.latest.cpuPercentage, 20)
        XCTAssertEqual(snapshots.requestCount(for: 101), 3)

        monitor.select(
            processIdentifier: 101,
            launchDate: Date(timeIntervalSince1970: 1),
            isRunning: { true }
        )

        XCTAssertEqual(recorder.latest.cpuPercentage, 10)
        XCTAssertEqual(recorder.latest.memoryBytes, 202)

        await waitForRequestCount(4, pid: 101, snapshots: snapshots)
        snapshots.send(
            snapshot(pid: 101, time: 3_000, cpu: 1_000, memory: 505),
            to: 101
        )
        await waitForRequestCount(5, pid: 101, snapshots: snapshots)

        XCTAssertEqual(recorder.latest.cpuPercentage, 80)
        XCTAssertEqual(recorder.latest.memoryBytes, 505)
        XCTAssertEqual(snapshots.requestCount(for: 202), 3)

        monitor.stopSession()
        monitor.select(
            processIdentifier: 101,
            launchDate: Date(timeIntervalSince1970: 1),
            isRunning: { true }
        )

        XCTAssertNil(recorder.latest.cpuPercentage)

        monitor.stopSession()
        snapshots.finish()
    }

    func testReportsUnavailableUsageWhenTheSelectedApplicationQuits() async {
        let snapshots = ControlledSnapshotProvider()
        let recorder = ResourceUsageRecorder()
        let running = RunningFlag()
        let monitor = ApplicationResourceUsageMonitor(
            initialSampleInterval: .zero,
            refreshInterval: .zero,
            launchDateProvider: { _ in nil },
            snapshotProvider: { pid in
                await snapshots.next(for: pid)
            },
            onUpdate: { recorder.latest = $0 }
        )

        monitor.select(
            processIdentifier: 101,
            launchDate: Date(timeIntervalSince1970: 1),
            isRunning: { running.value }
        )
        snapshots.send(
            snapshot(pid: 101, time: 1_000, cpu: 100, memory: 101),
            to: 101
        )
        await waitForRequestCount(2, pid: 101, snapshots: snapshots)
        XCTAssertEqual(recorder.latest.memoryBytes, 101)

        running.value = false
        snapshots.send(
            snapshot(pid: 101, time: 2_000, cpu: 200, memory: 202),
            to: 101
        )
        await waitForUpdate(recorder) { $0.runningDuration == nil }

        XCTAssertNil(recorder.latest.memoryBytes)
        XCTAssertEqual(snapshots.requestCount(for: 101), 2)
        monitor.stopSession()
        snapshots.finish()
    }

    func testResolvesMissingApplicationLaunchDate() async {
        let snapshots = ControlledSnapshotProvider()
        let recorder = ResourceUsageRecorder()
        let launchDate = Date().addingTimeInterval(-3_600)
        let monitor = ApplicationResourceUsageMonitor(
            initialSampleInterval: .zero,
            refreshInterval: .zero,
            launchDateProvider: { pid in
                XCTAssertEqual(pid, 101)
                return launchDate
            },
            snapshotProvider: { pid in
                await snapshots.next(for: pid)
            },
            onUpdate: { recorder.latest = $0 }
        )

        monitor.select(
            processIdentifier: 101,
            launchDate: nil,
            isRunning: { true }
        )
        snapshots.send(
            snapshot(pid: 101, time: 1_000, cpu: 100, memory: 101),
            to: 101
        )
        await waitForRequestCount(2, pid: 101, snapshots: snapshots)

        XCTAssertEqual(recorder.latest.runningDuration ?? -1, 3_600, accuracy: 2)
        monitor.stopSession()
        snapshots.finish()
    }

    func testUnavailableLaunchDateKeepsOtherMetricsAvailable() async {
        let snapshots = ControlledSnapshotProvider()
        let recorder = ResourceUsageRecorder()
        let monitor = ApplicationResourceUsageMonitor(
            initialSampleInterval: .zero,
            refreshInterval: .zero,
            launchDateProvider: { _ in nil },
            snapshotProvider: { pid in
                await snapshots.next(for: pid)
            },
            onUpdate: { recorder.latest = $0 }
        )

        monitor.select(
            processIdentifier: 101,
            launchDate: nil,
            isRunning: { true }
        )
        snapshots.send(
            snapshot(pid: 101, time: 1_000, cpu: 100, memory: 101),
            to: 101
        )
        await waitForRequestCount(2, pid: 101, snapshots: snapshots)

        XCTAssertNil(recorder.latest.runningDuration)
        XCTAssertEqual(recorder.latest.memoryBytes, 101)
        monitor.stopSession()
        snapshots.finish()
    }

    func testReadsCurrentProcessLaunchDateFromKernel() async throws {
        let beforeQuery = Date()
        let result = await ApplicationResourceUsageMonitor.processLaunchDate(
            for: getpid()
        )
        let launchDate = try XCTUnwrap(result)

        XCTAssertLessThanOrEqual(launchDate, beforeQuery)
        XCTAssertGreaterThan(launchDate.timeIntervalSince1970, 0)
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        pid: pid_t,
        snapshots: ControlledSnapshotProvider
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while snapshots.requestCount(for: pid) < expectedCount {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for resource sampler")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForUpdate(
        _ recorder: ResourceUsageRecorder,
        until isExpected: (ApplicationResourceUsage) -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while !isExpected(recorder.latest) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for a resource usage update")
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

@MainActor
private final class RunningFlag {
    var value = true
}

/// Hands out snapshots on request. A request whose task is cancelled, as
/// the monitor's real sampler is, returns nil instead of consuming one.
private final class ControlledSnapshotProvider: Sendable {
    private typealias Continuation = CheckedContinuation<
        ProcessTreeResourceSnapshot?,
        Never
    >

    private struct Waiter {
        let id: UInt64
        let continuation: Continuation
    }

    private struct State {
        var queuedSnapshots: [pid_t: [ProcessTreeResourceSnapshot]] = [:]
        var waiters: [pid_t: [Waiter]] = [:]
        var requestCounts: [pid_t: Int] = [:]
        var nextRequestID: UInt64 = 0
        var isFinished = false
    }

    private let state = Mutex(State())

    func next(for pid: pid_t) async -> ProcessTreeResourceSnapshot? {
        let requestID = state.withLock { state in
            state.requestCounts[pid, default: 0] += 1
            state.nextRequestID += 1
            return state.nextRequestID
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let answer: ProcessTreeResourceSnapshot?? = state.withLock {
                    state in
                    if var queued = state.queuedSnapshots[pid],
                       !queued.isEmpty {
                        let snapshot = queued.removeFirst()
                        state.queuedSnapshots[pid] = queued
                        return .some(snapshot)
                    }
                    guard !state.isFinished, !Task.isCancelled else {
                        return .some(nil)
                    }

                    state.waiters[pid, default: []].append(
                        Waiter(id: requestID, continuation: continuation)
                    )
                    return .none
                }
                if case let .some(snapshot) = answer {
                    continuation.resume(returning: snapshot)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters[pid]?.firstIndex(where: {
                    $0.id == requestID
                }) else {
                    return nil
                }
                return state.waiters[pid]?.remove(at: index)
            }
            waiter?.continuation.resume(returning: nil)
        }
    }

    func send(_ snapshot: ProcessTreeResourceSnapshot, to pid: pid_t) {
        let waiter = state.withLock { state -> Waiter? in
            if let waiters = state.waiters[pid], !waiters.isEmpty {
                return state.waiters[pid]?.removeFirst()
            }
            state.queuedSnapshots[pid, default: []].append(snapshot)
            return nil
        }
        waiter?.continuation.resume(returning: snapshot)
    }

    func requestCount(for pid: pid_t) -> Int {
        state.withLock { $0.requestCounts[pid, default: 0] }
    }

    func finish() {
        let waiters = state.withLock { state in
            state.isFinished = true
            state.queuedSnapshots.removeAll()
            let waiters = state.waiters.values.flatMap { $0 }
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
    }
}
