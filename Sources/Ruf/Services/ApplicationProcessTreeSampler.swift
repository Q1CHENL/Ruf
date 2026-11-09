import Darwin
import RufCore

struct ApplicationProcessTreeSampler: Sendable {
    struct Query: Sendable {
        let capturedAt: @Sendable () -> UInt64
        let processRelationships: @Sendable () -> [ProcessRelationship]?
        let processCounters: @Sendable (pid_t) -> ProcessResourceCounters?
    }

    private typealias PIDRUsageFunction = @convention(c) (
        Int32,
        Int32,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias ListAllPIDsFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32
    ) -> Int32
    private typealias PIDInfoFunction = @convention(c) (
        Int32,
        Int32,
        UInt64,
        UnsafeMutableRawPointer?,
        Int32
    ) -> Int32
    private typealias ResponsiblePIDFunction = @convention(c) (
        pid_t
    ) -> pid_t

    private struct Entrypoints: Sendable {
        let pidRUsage: PIDRUsageFunction
        let listAllPIDs: ListAllPIDsFunction
        let pidInfo: PIDInfoFunction
        // Without it, a process counts toward an application only through
        // its parent links, which miss the XPC services launchd starts for it.
        let responsiblePID: ResponsiblePIDFunction?
    }

    private static let maximumProcessTableReads = 3

    // libproc and the responsibility query are private and explicitly
    // subject to change. Resolve them at runtime so their removal makes this
    // optional display unavailable, or less complete, instead of preventing
    // Ruf from launching.
    private static let entrypoints: Entrypoints? = {
        guard let processHandle = dlopen(nil, RTLD_LAZY),
              let pidRUsage = dlsym(processHandle, "proc_pid_rusage"),
              let listAllPIDs = dlsym(processHandle, "proc_listallpids"),
              let pidInfo = dlsym(processHandle, "proc_pidinfo") else {
            return nil
        }

        return Entrypoints(
            pidRUsage: unsafeBitCast(
                pidRUsage,
                to: PIDRUsageFunction.self
            ),
            listAllPIDs: unsafeBitCast(
                listAllPIDs,
                to: ListAllPIDsFunction.self
            ),
            pidInfo: unsafeBitCast(
                pidInfo,
                to: PIDInfoFunction.self
            ),
            responsiblePID: dlsym(
                processHandle,
                "responsibility_get_pid_responsible_for_pid"
            ).map {
                unsafeBitCast($0, to: ResponsiblePIDFunction.self)
            }
        )
    }()

    private static let systemQuery: Query? = {
        guard let entrypoints else {
            return nil
        }

        return Query(
            capturedAt: { mach_absolute_time() },
            processRelationships: {
                Self.processRelationships(using: entrypoints)
            },
            processCounters: { processIdentifier in
                Self.processCounters(
                    for: processIdentifier,
                    using: entrypoints.pidRUsage
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
        guard let relationships = query.processRelationships() else {
            return nil
        }

        var processes: [ProcessResourceCounters] = []
        for processIdentifier in ApplicationProcessGroup.memberPIDs(
            of: rootPID,
            in: relationships
        ) {
            guard !Task.isCancelled else {
                return nil
            }

            if let counters = query.processCounters(processIdentifier) {
                processes.append(counters)
            } else if processIdentifier == rootPID {
                return nil
            }
            // Another member can exit, or keep its counters protected,
            // between the table pass and this read. The rest still count.
        }

        guard let rootCounters = processes.first else {
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

    private static func processRelationships(
        using entrypoints: Entrypoints
    ) -> [ProcessRelationship]? {
        guard let processIdentifiers = allProcessIdentifiers(
            using: entrypoints.listAllPIDs
        ) else {
            return nil
        }

        return processIdentifiers.compactMap { processIdentifier in
            guard processIdentifier > 0 else {
                return nil
            }

            let responsiblePID = entrypoints.responsiblePID.flatMap {
                function in
                let responsiblePID = function(processIdentifier)
                return responsiblePID > 0 ? responsiblePID : nil
            }
            return ProcessRelationship(
                pid: processIdentifier,
                parentPID: parentPID(
                    of: processIdentifier,
                    using: entrypoints.pidInfo
                ),
                responsiblePID: responsiblePID
            )
        }
    }

    private static func allProcessIdentifiers(
        using function: ListAllPIDsFunction
    ) -> [pid_t]? {
        // A null buffer returns an estimate of the process count. Leave room
        // for processes started since, and read again if the table still
        // filled the buffer.
        var capacity = Int(function(nil, 0))
        guard capacity > 0 else {
            return nil
        }

        for _ in 0..<Self.maximumProcessTableReads {
            capacity += capacity / 4
            var processIdentifiers = [pid_t](repeating: 0, count: capacity)
            let count = processIdentifiers.withUnsafeMutableBytes { buffer in
                function(buffer.baseAddress, Int32(buffer.count))
            }

            guard count > 0, count <= capacity else {
                return nil
            }
            if count < capacity {
                return Array(processIdentifiers.prefix(Int(count)))
            }
        }

        return nil
    }

    private static func parentPID(
        of processIdentifier: pid_t,
        using function: PIDInfoFunction
    ) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let result = withUnsafeMutableBytes(of: &info) { buffer in
            function(
                processIdentifier,
                PROC_PIDT_SHORTBSDINFO,
                0,
                buffer.baseAddress,
                size
            )
        }
        guard result == size else {
            return nil
        }

        return pid_t(bitPattern: info.pbsi_ppid)
    }

    private static func processCounters(
        for processIdentifier: pid_t,
        using function: PIDRUsageFunction
    ) -> ProcessResourceCounters? {
        var info = rusage_info_v0()
        let capturedAt = mach_absolute_time()
        let result = withUnsafeMutableBytes(of: &info) { buffer in
            function(processIdentifier, 0, buffer.baseAddress)
        }
        guard result == 0 else {
            return nil
        }

        let cpuTime = info.ri_user_time.addingReportingOverflow(
            info.ri_system_time
        )
        guard !cpuTime.overflow else {
            return nil
        }

        return ProcessResourceCounters(
            identity: ProcessResourceIdentity(
                pid: processIdentifier,
                startTime: info.ri_proc_start_abstime
            ),
            capturedAt: capturedAt,
            cumulativeCPUTime: cpuTime.partialValue,
            physicalFootprintBytes: info.ri_phys_footprint
        )
    }
}
