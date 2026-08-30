import Darwin
import RufCore

struct ApplicationProcessTreeSampler: Sendable {
    enum QueryResult<Value: Sendable>: Sendable {
        case success(Value)
        case disappeared
        case unavailable
    }

    struct Query: Sendable {
        let capturedAt: @Sendable () -> UInt64
        let processCounters: @Sendable (pid_t) ->
            QueryResult<ProcessResourceCounters>
        let childPIDs: @Sendable (pid_t) -> QueryResult<[pid_t]>
    }

    private typealias PIDRUsageFunction = @convention(c) (
        Int32,
        Int32,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias ListChildPIDsFunction = @convention(c) (
        pid_t,
        UnsafeMutableRawPointer?,
        Int32
    ) -> Int32

    private struct Entrypoints: Sendable {
        let pidRUsage: PIDRUsageFunction
        let listChildPIDs: ListChildPIDsFunction
    }

    private static let initialChildCapacity = 16
    private static let maximumProcessCount = 512

    // libproc is private and explicitly subject to change. Resolve its two
    // entry points at runtime so their removal makes this optional display
    // unavailable instead of preventing Ruf from launching.
    private static let entrypoints: Entrypoints? = {
        guard let processHandle = dlopen(nil, RTLD_LAZY),
              let pidRUsage = dlsym(processHandle, "proc_pid_rusage"),
              let listChildPIDs = dlsym(
                  processHandle,
                  "proc_listchildpids"
              ) else {
            return nil
        }

        return Entrypoints(
            pidRUsage: unsafeBitCast(
                pidRUsage,
                to: PIDRUsageFunction.self
            ),
            listChildPIDs: unsafeBitCast(
                listChildPIDs,
                to: ListChildPIDsFunction.self
            )
        )
    }()

    private static let systemQuery: Query? = {
        guard let entrypoints else {
            return nil
        }

        return Query(
            capturedAt: { mach_absolute_time() },
            processCounters: { processIdentifier in
                Self.processCounters(
                    for: processIdentifier,
                    using: entrypoints.pidRUsage
                )
            },
            childPIDs: { processIdentifier in
                Self.childPIDs(
                    of: processIdentifier,
                    using: entrypoints.listChildPIDs
                )
            }
        )
    }()

    private let query: Query?

    init() {
        query = Self.systemQuery
    }

    init(query: Query?) {
        self.query = query
    }

    func snapshot(for rootPID: pid_t) -> ProcessTreeResourceSnapshot? {
        guard rootPID > 0, let query else {
            return nil
        }

        let capturedAt = query.capturedAt()
        var pendingPIDs = [rootPID]
        var visitedPIDs: Set<pid_t> = [rootPID]
        var pendingIndex = 0
        var processes: [ProcessResourceCounters] = []

        while pendingIndex < pendingPIDs.count {
            guard !Task.isCancelled else {
                return nil
            }

            let processIdentifier = pendingPIDs[pendingIndex]
            pendingIndex += 1

            switch query.processCounters(processIdentifier) {
            case let .success(counters):
                processes.append(counters)
            case .disappeared where processIdentifier != rootPID:
                continue
            case .unavailable where processIdentifier != rootPID:
                // Resource counters can be protected even when child-process
                // enumeration remains available. Keep traversing the tree.
                break
            case .disappeared, .unavailable:
                return nil
            }

            switch query.childPIDs(processIdentifier) {
            case let .success(childPIDs):
                for childPID in childPIDs where childPID > 0 {
                    guard visitedPIDs.insert(childPID).inserted else {
                        continue
                    }
                    guard visitedPIDs.count <= Self.maximumProcessCount else {
                        return nil
                    }
                    pendingPIDs.append(childPID)
                }
            case .disappeared where processIdentifier != rootPID:
                continue
            case .disappeared, .unavailable:
                return nil
            }
        }

        guard let rootCounters = processes.first(where: {
            $0.identity.pid == rootPID
        }) else {
            return nil
        }

        let snapshot = ProcessTreeResourceSnapshot(
            capturedAt: capturedAt,
            rootIdentity: rootCounters.identity,
            processes: processes
        )
        guard snapshot.physicalFootprintBytes != nil else {
            return nil
        }
        return snapshot
    }

    private static func processCounters(
        for processIdentifier: pid_t,
        using function: PIDRUsageFunction
    ) -> QueryResult<ProcessResourceCounters> {
        var info = rusage_info_v0()
        errno = 0
        let capturedAt = mach_absolute_time()
        let result = withUnsafeMutableBytes(of: &info) { buffer in
            function(processIdentifier, 0, buffer.baseAddress)
        }
        guard result == 0 else {
            return errno == ESRCH ? .disappeared : .unavailable
        }

        let cpuTime = info.ri_user_time.addingReportingOverflow(
            info.ri_system_time
        )
        guard !cpuTime.overflow else {
            return .unavailable
        }

        return .success(
            ProcessResourceCounters(
                identity: ProcessResourceIdentity(
                    pid: processIdentifier,
                    startTime: info.ri_proc_start_abstime
                ),
                capturedAt: capturedAt,
                cumulativeCPUTime: cpuTime.partialValue,
                physicalFootprintBytes: info.ri_phys_footprint
            )
        )
    }

    private static func childPIDs(
        of processIdentifier: pid_t,
        using function: ListChildPIDsFunction
    ) -> QueryResult<[pid_t]> {
        var capacity = Self.initialChildCapacity

        while capacity <= Self.maximumProcessCount {
            var processIdentifiers = [pid_t](
                repeating: 0,
                count: capacity
            )
            errno = 0
            let count = processIdentifiers.withUnsafeMutableBytes { buffer in
                function(
                    processIdentifier,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }

            guard count >= 0 else {
                return errno == ESRCH ? .disappeared : .unavailable
            }
            if count == 0 {
                guard errno == 0 else {
                    return errno == ESRCH ? .disappeared : .unavailable
                }
                return .success([])
            }
            guard count <= capacity else {
                return .unavailable
            }
            guard count == capacity else {
                return .success(Array(processIdentifiers.prefix(Int(count))))
            }
            guard capacity < Self.maximumProcessCount else {
                return .unavailable
            }

            capacity = min(capacity * 2, Self.maximumProcessCount)
        }

        return .unavailable
    }
}
