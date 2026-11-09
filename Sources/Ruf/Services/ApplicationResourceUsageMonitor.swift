import AppKit
import RufCore

@MainActor
final class ApplicationResourceUsageMonitor {
    typealias LaunchDateProvider = @Sendable (pid_t) async -> Date?
    typealias SnapshotProvider = @Sendable (pid_t) async ->
        ProcessTreeResourceSnapshot?

    private struct Target: Hashable {
        let processIdentifier: pid_t
        let launchDate: Date?
    }

    /// What a session learned about a target. It outlives the selection so
    /// a revisit shows a value at once, and the first fresh snapshot yields
    /// CPU averaged over the time the selection was elsewhere.
    private struct TargetUsage {
        var latestUsage: ApplicationResourceUsage
        var cpuBaseline = ProcessCPUUsageBaseline()
    }

    private let initialSampleInterval: Duration
    private let refreshInterval: Duration
    private let launchDateProvider: LaunchDateProvider
    private let snapshotProvider: SnapshotProvider
    private let onUpdate:
        @MainActor @Sendable (ApplicationResourceUsage) -> Void
    private var usageByTarget: [Target: TargetUsage] = [:]
    // Only the selected target is sampled. A running task always belongs to
    // it, and a cancelled one never touches the monitor's state again.
    private var selectedTarget: Target?
    private var samplingTask: Task<Void, Never>?

    init(
        onUpdate: @escaping @MainActor @Sendable (
            ApplicationResourceUsage
        ) -> Void
    ) {
        initialSampleInterval = .milliseconds(500)
        refreshInterval = .seconds(1)
        launchDateProvider = Self.processLaunchDate
        snapshotProvider = Self.sample
        self.onUpdate = onUpdate
    }

    init(
        initialSampleInterval: Duration,
        refreshInterval: Duration,
        launchDateProvider: @escaping LaunchDateProvider,
        snapshotProvider: @escaping SnapshotProvider,
        onUpdate: @escaping @MainActor @Sendable (
            ApplicationResourceUsage
        ) -> Void
    ) {
        self.initialSampleInterval = initialSampleInterval
        self.refreshInterval = refreshInterval
        self.launchDateProvider = launchDateProvider
        self.snapshotProvider = snapshotProvider
        self.onUpdate = onUpdate
    }

    func select(_ application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        select(
            processIdentifier: processIdentifier,
            launchDate: application.launchDate,
            isRunning: { [weak application] in
                guard let application else {
                    return false
                }
                return !application.isTerminated
                    && application.processIdentifier == processIdentifier
            }
        )
    }

    func select(
        processIdentifier: pid_t,
        launchDate: Date?,
        isRunning: @escaping @MainActor @Sendable () -> Bool
    ) {
        let target = Target(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        guard target.processIdentifier > 0,
              isRunning() else {
            deselect()
            onUpdate(unavailableUsage)
            return
        }

        let usage = usageByTarget[target] ?? TargetUsage(
            latestUsage: ApplicationResourceUsage(
                cpuPercentage: nil,
                memoryBytes: nil,
                runningDuration: runningDuration(since: launchDate)
            )
        )
        usageByTarget[target] = usage
        onUpdate(usage.latestUsage)

        guard target != selectedTarget else {
            return
        }

        samplingTask?.cancel()
        selectedTarget = target
        samplingTask = Task { [weak self] in
            await self?.sample(target, isRunning: isRunning)
        }
    }

    func deselect() {
        samplingTask?.cancel()
        samplingTask = nil
        selectedTarget = nil
    }

    func stopSession() {
        deselect()
        usageByTarget.removeAll()
    }

    private var unavailableUsage: ApplicationResourceUsage {
        ApplicationResourceUsage(
            cpuPercentage: nil,
            memoryBytes: nil,
            runningDuration: nil
        )
    }

    private func runningDuration(since launchDate: Date?) -> TimeInterval? {
        launchDate.map { max(0, Date().timeIntervalSince($0)) }
    }

    private func sample(
        _ target: Target,
        isRunning: @MainActor @Sendable () -> Bool
    ) async {
        var launchDate = target.launchDate
        if launchDate == nil {
            launchDate = await launchDateProvider(target.processIdentifier)
        }

        var interval = initialSampleInterval
        while !Task.isCancelled, isRunning() {
            let snapshot = await snapshotProvider(target.processIdentifier)
            guard !Task.isCancelled else {
                return
            }
            guard isRunning() else {
                break
            }

            record(snapshot, for: target, launchDate: launchDate)

            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            interval = refreshInterval
        }
        guard !Task.isCancelled else {
            return
        }

        // The application quit while selected.
        usageByTarget[target] = nil
        samplingTask = nil
        selectedTarget = nil
        onUpdate(unavailableUsage)
    }

    private func record(
        _ snapshot: ProcessTreeResourceSnapshot?,
        for target: Target,
        launchDate: Date?
    ) {
        guard var usage = usageByTarget[target] else {
            return
        }

        if let snapshot,
           let memoryBytes = snapshot.physicalFootprintBytes {
            usage.latestUsage = ApplicationResourceUsage(
                cpuPercentage: usage.cpuBaseline.update(snapshot: snapshot),
                memoryBytes: memoryBytes,
                runningDuration: runningDuration(since: launchDate)
            )
        } else {
            usage.cpuBaseline = ProcessCPUUsageBaseline()
            usage.latestUsage = ApplicationResourceUsage(
                cpuPercentage: nil,
                memoryBytes: nil,
                runningDuration: runningDuration(since: launchDate)
            )
        }
        usageByTarget[target] = usage
        onUpdate(usage.latestUsage)
    }

    nonisolated static func processLaunchDate(
        for processIdentifier: pid_t
    ) async -> Date? {
        await Task.detached(priority: .utility) {
            guard processIdentifier > 0 else {
                return nil
            }

            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [
                CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier,
            ]
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
                  size == MemoryLayout<kinfo_proc>.stride else {
                return nil
            }

            // Calendar start time preserves elapsed time across system sleep.
            let start = info.kp_proc.p_un.__p_starttime
            guard start.tv_sec > 0 else {
                return nil
            }
            return Date(timeIntervalSince1970:
                Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
            )
        }.value
    }

    private nonisolated static func sample(
        processIdentifier: pid_t
    ) async -> ProcessTreeResourceSnapshot? {
        let samplingTask = Task.detached(priority: .utility) {
            ApplicationProcessTreeSampler().snapshot(
                for: processIdentifier
            )
        }
        return await withTaskCancellationHandler {
            await samplingTask.value
        } onCancel: {
            samplingTask.cancel()
        }
    }
}
