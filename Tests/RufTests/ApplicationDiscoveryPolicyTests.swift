import AppKit
import RufCore
import XCTest

@testable import Ruf

final class ApplicationDiscoveryPolicyTests: XCTestCase {
    func testMapsApplicationTypesToDiscoveryPolicy() {
        XCTAssertEqual(
            ApplicationDiscoveryPolicy(activationPolicy: .regular, isCurrentApplication: false),
            .regular
        )
        XCTAssertEqual(
            ApplicationDiscoveryPolicy(activationPolicy: .accessory, isCurrentApplication: false),
            .windowsOnly
        )
        XCTAssertEqual(
            ApplicationDiscoveryPolicy(activationPolicy: .prohibited, isCurrentApplication: false),
            .excluded
        )
    }

    func testRufUsesItsSettingsEntryInsteadOfOrdinaryDiscovery() {
        for activationPolicy in [NSApplication.ActivationPolicy.regular, .accessory, .prohibited] {
            XCTAssertEqual(
                ApplicationDiscoveryPolicy(activationPolicy: activationPolicy, isCurrentApplication: true),
                .excluded
            )
        }
    }
}
