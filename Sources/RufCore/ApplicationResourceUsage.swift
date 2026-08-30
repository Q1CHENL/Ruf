import Foundation

public struct ProcessResourceIdentity: Hashable, Sendable {
    public let pid: Int32
    // Same Mach absolute-time unit returned by proc_pid_rusage.
    public let startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}

public struct ProcessResourceCounters: Equatable, Sendable {
    public let identity: ProcessResourceIdentity
    // Counter read time and CPU time use Mach absolute-time units.
    public let capturedAt: UInt64
    public let cumulativeCPUTime: UInt64
    public let physicalFootprintBytes: UInt64

    public init(
        identity: ProcessResourceIdentity,
        capturedAt: UInt64,
        cumulativeCPUTime: UInt64,
        physicalFootprintBytes: UInt64
    ) {
        self.identity = identity
        self.capturedAt = capturedAt
        self.cumulativeCPUTime = cumulativeCPUTime
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public struct ProcessTreeResourceSnapshot: Equatable, Sendable {
    // Start of traversal, used to identify processes born between snapshots.
    public let capturedAt: UInt64
    public let rootIdentity: ProcessResourceIdentity
    public let processes: [ProcessResourceCounters]
    public let physicalFootprintBytes: UInt64?

    public init(
        capturedAt: UInt64,
        rootIdentity: ProcessResourceIdentity,
        processes: [ProcessResourceCounters]
    ) {
        self.capturedAt = capturedAt
        self.rootIdentity = rootIdentity
        self.processes = processes
        physicalFootprintBytes = Self.totalPhysicalFootprint(processes)
    }

    private static func totalPhysicalFootprint(
        _ processes: [ProcessResourceCounters]
    ) -> UInt64? {
        var total: UInt64 = 0
        for process in processes {
            let sum = total.addingReportingOverflow(
                process.physicalFootprintBytes
            )
            guard !sum.overflow else {
                return nil
            }
            total = sum.partialValue
        }
        return total
    }
}

public struct ProcessCPUUsageBaseline: Sendable {
    private var previousSnapshot: ProcessTreeResourceSnapshot?

    public init() {}

    public mutating func update(
        snapshot: ProcessTreeResourceSnapshot
    ) -> Double? {
        defer {
            previousSnapshot = snapshot
        }

        guard let previousSnapshot,
              previousSnapshot.rootIdentity == snapshot.rootIdentity,
              snapshot.capturedAt > previousSnapshot.capturedAt else {
            return nil
        }

        var previousByIdentity:
            [ProcessResourceIdentity: ProcessResourceCounters] = [:]
        for process in previousSnapshot.processes {
            previousByIdentity[process.identity] = process
        }
        var percentage: Double = 0
        var contributingProcessCount = 0
        for process in snapshot.processes {
            let delta: UInt64
            let intervalStart: UInt64
            if let previous = previousByIdentity[process.identity] {
                guard process.cumulativeCPUTime >= previous.cumulativeCPUTime else {
                    return nil
                }
                delta = process.cumulativeCPUTime - previous.cumulativeCPUTime
                intervalStart = previous.capturedAt
            } else if process.identity.startTime >= previousSnapshot.capturedAt {
                delta = process.cumulativeCPUTime
                intervalStart = previousSnapshot.capturedAt
            } else {
                continue
            }

            guard process.capturedAt > intervalStart else {
                return nil
            }
            percentage += Double(delta)
                / Double(process.capturedAt - intervalStart) * 100
            contributingProcessCount += 1
        }

        return contributingProcessCount > 0 ? percentage : nil
    }
}

public struct ApplicationResourceUsage: Equatable, Sendable {
    public let cpuPercentage: Double?
    public let memoryBytes: UInt64?
    public let runningDuration: TimeInterval?

    public init(
        cpuPercentage: Double?,
        memoryBytes: UInt64?,
        runningDuration: TimeInterval?
    ) {
        self.cpuPercentage = cpuPercentage
        self.memoryBytes = memoryBytes
        self.runningDuration = runningDuration
    }
}

public enum ApplicationResourceUsageFormatter {
    private static let locale = Locale(identifier: "en_US_POSIX")

    public static func string(
        cpuPercentage: Double?,
        memoryBytes: UInt64?,
        runningDuration: TimeInterval?
    ) -> String {
        "CPU \(cpuString(cpuPercentage))"
            + " · Memory \(memoryString(memoryBytes))"
            + " · Running \(runningDurationString(runningDuration))"
    }

    public static func cpuString(_ percentage: Double?) -> String {
        guard let percentage, percentage.isFinite, percentage >= 0 else {
            return "—"
        }

        return String(
            format: "%.1f%%",
            locale: locale,
            percentage
        )
    }

    public static func memoryString(_ bytes: UInt64?) -> String {
        guard let bytes else {
            return "—"
        }

        if bytes >= 1_000_000_000 {
            return String(
                format: "%.1f GB",
                locale: locale,
                Double(bytes) / 1_000_000_000
            )
        }

        return String(
            format: "%.0f MB",
            locale: locale,
            Double(bytes) / 1_000_000
        )
    }

    public static func runningDurationString(
        _ duration: TimeInterval?
    ) -> String {
        guard let duration, duration.isFinite, duration >= 0 else {
            return "—"
        }

        let totalMinutes = Int(duration) / 60
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes / 60 % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }

        return "<1m"
    }
}
