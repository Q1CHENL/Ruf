import Foundation
import os

// Accessibility dominates every user-visible delay in the switcher, and its
// cost is a property of the applications being queried rather than of Ruf.
// Durations are therefore recorded rather than inferred, two ways that answer
// different questions: signposts place the intervals on an Instruments
// timeline beside the system activity that explains them, and a text file
// keeps them readable afterwards without a profiler attached.
enum PerformanceLog {
    struct Span: Sendable {
        fileprivate let name: StaticString
        fileprivate let start: DispatchTime
        fileprivate let interval: OSSignpostIntervalState
    }

    // Measuring is opt-in: a downloaded build should neither write to the
    // user's log directory nor pay for records nobody asked for.
    // `script/build_and_run.sh --telemetry` turns this on.
    private static let isEnabled = UserDefaults.standard.bool(
        forKey: "RufPerformanceLogging"
    )

    // Signposts put these intervals on an Instruments timeline, against the
    // window server, Accessibility, and SwiftUI activity that the text records
    // cannot show. They follow the same preference rather than staying armed:
    // measured on macOS 27, an emitting interval costs ~700ns whatever its
    // category, because signposts are enabled by default there rather than
    // only while a profiler records. A disabled handle costs ~93ns.
    private static let signposter = isEnabled
        ? OSSignposter(
            logHandle: OSLog(
                subsystem: "com.qichen.ruf",
                category: .pointsOfInterest
            )
        )
        : OSSignposter(logHandle: .disabled)

    // A file rather than the unified log: under load that log evicts info
    // records within seconds, which makes a run unreadable by the time anyone
    // looks. These records outlive the session that produced them.
    private static let file = isEnabled ? PerformanceLogFile() : nil

    static var fileURL: URL? {
        PerformanceLogFile.url
    }

    // Diagnostics that have to sample state before they can format it -- window
    // geometry, screen membership, a WindowServer readback -- pay for the
    // sampling whether or not anyone is measuring. Gating only the message
    // leaves that cost on the hot path, so the whole body is gated instead.
    static func whenEnabled(_ body: () -> Void) {
        guard isEnabled else {
            return
        }

        body()
    }

    static func begin(_ name: StaticString) -> Span {
        // Spans nest and run concurrently, so each interval needs its own
        // identifier; the shared `.exclusive` one cannot tell them apart.
        Span(
            name: name,
            start: .now(),
            interval: signposter.beginInterval(
                name,
                id: signposter.makeSignpostID()
            )
        )
    }

    static func end(_ span: Span, _ detail: String? = nil) {
        signposter.endInterval(span.name, span.interval)
        record(
            span.name,
            nanoseconds: DispatchTime.now().uptimeNanoseconds
                &- span.start.uptimeNanoseconds,
            detail
        )
    }

    // Costs that are spread across a loop rather than contiguous have to be
    // accumulated by the caller and reported once.
    static func record(
        _ name: StaticString,
        nanoseconds: UInt64,
        _ detail: String? = nil
    ) {
        guard isEnabled else {
            return
        }

        let elapsed = Double(nanoseconds) / 1_000_000
        let suffix = detail.map { " \($0)" } ?? ""

        file?.append(
            name: "\(name)",
            milliseconds: elapsed,
            suffix: suffix,
            timestamp: Date()
        )
    }
}

private final class PerformanceLogFile: @unchecked Sendable {
    private static let maximumByteCount = 4 * 1024 * 1024

    static let url: URL? = {
        guard let directory = try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }

        return directory
            .appending(path: "Logs/Ruf", directoryHint: .isDirectory)
            .appending(path: "performance.log", directoryHint: .notDirectory)
    }()

    private let queue = DispatchQueue(
        label: "com.qichen.ruf.performance-log",
        qos: .utility
    )
    private let handle: FileHandle
    private let formatter: DateFormatter

    init?() {
        guard let url = Self.url else {
            return nil
        }

        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        guard (try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else {
            return nil
        }

        if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            guard fileManager.createFile(
                atPath: url.path(percentEncoded: false),
                contents: nil
            ) else {
                return nil
            }
        }

        // Records accumulate across sessions so runs can be compared, which
        // needs a ceiling: a tight measurement loop reaches megabytes in
        // seconds. Older runs are dropped rather than allowed to grow.
        let size = (try? fileManager.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )[.size] as? Int) ?? 0
        if size > Self.maximumByteCount {
            try? Data().write(to: url)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }

        self.handle = handle
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        // Each launch is its own measurement session; a marker keeps the runs
        // in an accumulated file distinguishable.
        let pid = ProcessInfo.processInfo.processIdentifier
        write("\n--- session \(pid) started \(formatter.string(from: Date()))")
    }

    deinit {
        try? handle.close()
    }

    func append(
        name: String,
        milliseconds: Double,
        suffix: String,
        timestamp: Date
    ) {
        queue.async { [self] in
            let elapsed = String(format: "%.2f", milliseconds)
            write(
                "\(formatter.string(from: timestamp)) \(name) "
                    + "\(elapsed)ms\(suffix)"
            )
        }
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else {
            return
        }

        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
