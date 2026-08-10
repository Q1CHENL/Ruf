import Foundation
import XCTest

@testable import Ruf

final class PerformanceLogFileTests: XCTestCase {
    func testSingleSessionNeverExceedsMaximumByteCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let logURL = directory.appending(
            path: "performance.log",
            directoryHint: .notDirectory
        )
        let maximumByteCount = 256

        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let log = try XCTUnwrap(PerformanceLogFile(
            url: logURL,
            maximumByteCount: maximumByteCount
        ))
        for index in 0..<32 {
            log.append(
                name: "query-\(index)",
                milliseconds: Double(index),
                suffix: " \(String(repeating: "x", count: 24))",
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        log.flush()

        let data = try Data(contentsOf: logURL)
        let contents = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertLessThanOrEqual(data.count, maximumByteCount)
        XCTAssertTrue(contents.contains("query-31 "))
        XCTAssertFalse(contents.contains("query-0 "))
    }
}
