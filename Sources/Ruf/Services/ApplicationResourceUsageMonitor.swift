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

    private struct SamplerState {
        var latestUsage: ApplicationResourceUsage
        let task: Task<Void, Never>
    }

    private let initialSampleInterval: Duration
    private let refreshInterval: Duration
    private let launchDateProvider: LaunchDateProvider
    private let snapshotProvider: SnapshotProvider
    private let onUpdate:
        @MainActor @Sendable (ApplicationResourceUsage) -> Void
    private var samplers: [Target: SamplerState] = [:]
    private var selectedTarget: Target?
    private var generation: UInt64 = 0

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
        let nextTarget = Target(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        guard nextTarget.processIdentifier > 0,
              isRunning() else {
            selectedTarget = nil
            onUpdate(unavailableUsage)
            return
        }

        selectedTarget = nextTarget
        if let sampler = samplers[nextTarget] {
            onUpdate(sampler.latestUsage)
            return
        }

        let initialUsage = ApplicationResourceUsage(
            cpuPercentage: nil,
            memoryBytes: nil,
            runningDuration: runningDuration(
                since: nextTarget.launchDate
            )
        )
        onUpdate(initialUsage)

        let expectedGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let launchDate: Date?
            if let knownLaunchDate = nextTarget.launchDate {
                launchDate = knownLaunchDate
            } else {
                launchDate = await launchDateProvider(nextTarget.processIdentifier)
            }
            var cpuBaseline = ProcessCPUUsageBaseline()
            var isFirstInterval = true

            while !Task.isCancelled {
                guard generation == expectedGeneration,
                      samplers[nextTarget] != nil,
                      isRunning() else {
                    break
                }

                let processIdentifier = nextTarget.processIdentifier
                let snapshot = await snapshotProvider(processIdentifier)
                guard !Task.isCancelled,
                      generation == expectedGeneration,
                      samplers[nextTarget] != nil,
                      isRunning() else {
                    break
                }

                if let snapshot,
                   let memoryBytes = snapshot.physicalFootprintBytes {
                    publish(
                        ApplicationResourceUsage(
                            cpuPercentage: cpuBaseline.update(
                                snapshot: snapshot
                            ),
                            memoryBytes: memoryBytes,
                            runningDuration: runningDuration(
                                since: launchDate
                            )
                        ),
                        for: nextTarget,
                        generation: expectedGeneration
                    )
                } else {
                    cpuBaseline = ProcessCPUUsageBaseline()
                    publish(
                        ApplicationResourceUsage(
                            cpuPercentage: nil,
                            memoryBytes: nil,
                            runningDuration: runningDuration(
                                since: launchDate
                            )
                        ),
                        for: nextTarget,
                        generation: expectedGeneration
                    )
                }

                do {
                    try await Task.sleep(
                        for: isFirstInterval
                            ? initialSampleInterval
                            : refreshInterval
                    )
                } catch {
                    break
                }
                isFirstInterval = false
            }

            finishSampler(
                for: nextTarget,
                generation: expectedGeneration
            )
        }
        samplers[nextTarget] = SamplerState(
            latestUsage: initialUsage,
            task: task
        )
    }

    func deselect() {
        selectedTarget = nil
    }

    func stopSession() {
        generation &+= 1
        for sampler in samplers.values {
            sampler.task.cancel()
        }
        samplers.removeAll()
        selectedTarget = nil
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

    private func publish(
        _ usage: ApplicationResourceUsage,
        for target: Target,
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration,
              var sampler = samplers[target] else {
            return
        }

        sampler.latestUsage = usage
        samplers[target] = sampler
        guard selectedTarget == target else {
            return
        }
        onUpdate(usage)
    }

    private func finishSampler(
        for target: Target,
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration else {
            return
        }

        samplers[target] = nil
        guard selectedTarget == target else {
            return
        }
        selectedTarget = nil
        onUpdate(unavailableUsage)
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
