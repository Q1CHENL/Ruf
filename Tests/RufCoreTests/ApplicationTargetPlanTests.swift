import XCTest
@testable import RufCore

final class ApplicationTargetOrderTests: XCTestCase {
    func testOrdersApplicationsByRecencyThenName() {
        let ordered = ApplicationTargetPlan.ordered(
            [
                instance("notes", name: "Notes", processIdentifier: 1),
                instance("safari", name: "Safari", processIdentifier: 2),
                instance("mail", name: "Mail", processIdentifier: 3),
                instance("zed", name: "Zed", processIdentifier: 4),
                instance("atlas", name: "atlas", processIdentifier: 5),
            ],
            recentApplicationIdentifiers: ["mail", "gone", "safari"],
            recentProcessIdentifiers: []
        )

        XCTAssertEqual(
            ordered.map(\.item),
            ["mail", "safari", "atlas", "notes", "zed"]
        )
    }

    func testBreaksNameTiesByIdentifierSoTheOrderIsStable() {
        let ordered = ApplicationTargetPlan.ordered(
            [
                instance("b.helper", name: "Helper", processIdentifier: 1),
                instance("a.helper", name: "Helper", processIdentifier: 2),
            ],
            recentApplicationIdentifiers: [],
            recentProcessIdentifiers: []
        )

        XCTAssertEqual(ordered.map(\.item), ["a.helper", "b.helper"])
    }

    // Firefox profiles, `open -n` copies, and helpers that share a bundle
    // identifier are one application: they share its recency and stay
    // together, the instance the user last activated first.
    func testKeepsInstancesTogetherMostRecentlyActiveFirst() {
        let ordered = ApplicationTargetPlan.ordered(
            [
                instance("firefox", name: "Firefox", processIdentifier: 30),
                instance("mail", name: "Mail", processIdentifier: 25),
                instance("firefox", name: "Firefox Nightly", processIdentifier: 20),
                instance("firefox", name: "Firefox", processIdentifier: 40),
            ],
            recentApplicationIdentifiers: ["firefox", "mail"],
            recentProcessIdentifiers: [40, 25]
        )

        XCTAssertEqual(
            ordered.map(\.processIdentifier),
            [40, 20, 30, 25]
        )
    }

    // An application sorts by the name of its first instance, so instances
    // with different names cannot interleave with another application.
    func testInstancesWithDifferentNamesStayTogether() {
        let ordered = ApplicationTargetPlan.ordered(
            [
                instance("x", name: "Zulu", processIdentifier: 3),
                instance("y", name: "Mid", processIdentifier: 2),
                instance("x", name: "Alpha", processIdentifier: 1),
            ],
            recentApplicationIdentifiers: [],
            recentProcessIdentifiers: []
        )

        XCTAssertEqual(ordered.map(\.processIdentifier), [1, 3, 2])
    }
}

final class ApplicationOfferTests: XCTestCase {
    func testOffersASingleInstanceAsResolved() {
        for resolution: ApplicationWindowResolution<String> in [
            .application,
            .singleWindow("A"),
            .windowless,
            .windows(["A", "B"]),
        ] {
            XCTAssertEqual(
                offers([instance("app", processIdentifier: 1)], [1: resolution]),
                [offer("app", resolution)]
            )
        }
    }

    func testOffersAnInstanceThatWasNotResolvedAsTheApplication() {
        XCTAssertEqual(
            offers([instance("app", processIdentifier: 1)], [:]),
            [offer("app", .application)]
        )
    }

    // Two Firefox profiles: each one's windows are reachable, and every tile
    // shows its window title so the two can be told apart.
    func testOffersTheWindowsOfEveryInstance() {
        XCTAssertEqual(
            offers(
                [
                    instance("A", applicationIdentifier: "firefox", processIdentifier: 1),
                    instance("B", applicationIdentifier: "firefox", processIdentifier: 2),
                ],
                [1: .windows(["a1", "a2"]), 2: .singleWindow("b1")]
            ),
            [offer("A", .windows(["a1", "a2"])), offer("B", .windows(["b1"]))]
        )
    }

    func testAWindowlessInstanceDoesNotBadgeAnApplicationWithWindows() {
        XCTAssertEqual(
            offers(
                [
                    instance("A", applicationIdentifier: "firefox", processIdentifier: 1),
                    instance("B", applicationIdentifier: "firefox", processIdentifier: 2),
                ],
                [1: .windowless, 2: .singleWindow("b1")]
            ),
            [offer("B", .singleWindow("b1"))]
        )
        XCTAssertEqual(
            offers(
                [
                    instance("A", applicationIdentifier: "firefox", processIdentifier: 1),
                    instance("B", applicationIdentifier: "firefox", processIdentifier: 2),
                ],
                [1: .windowless, 2: .application]
            ),
            [offer("B", .application)]
        )
    }

    func testAnUnresolvedInstanceKeepsItsTileBesideAnotherInstancesWindows() {
        XCTAssertEqual(
            offers(
                [
                    instance("A", applicationIdentifier: "firefox", processIdentifier: 1),
                    instance("B", applicationIdentifier: "firefox", processIdentifier: 2),
                ],
                [1: .application, 2: .singleWindow("b1")]
            ),
            [offer("A", .application), offer("B", .windows(["b1"]))]
        )
    }

    func testOffersOneReopenTileForAnApplicationWithoutWindows() {
        XCTAssertEqual(
            offers(
                [
                    instance("A", applicationIdentifier: "firefox", processIdentifier: 1),
                    instance("B", applicationIdentifier: "firefox", processIdentifier: 2),
                ],
                [1: .windowless, 2: .windowless]
            ),
            [offer("A", .windowless)]
        )
    }

    // An accessory process that shares the application's bundle identifier
    // and has no windows of its own must not take the application's place.
    func testAWindowlessAccessoryInstanceLeavesTheApplicationInPlace() {
        XCTAssertEqual(
            offers(
                [
                    instance(
                        "helper",
                        applicationIdentifier: "app",
                        processIdentifier: 1,
                        policy: .windowsOnly
                    ),
                    instance("app", applicationIdentifier: "app", processIdentifier: 2),
                ],
                [1: .windowless, 2: .application]
            ),
            [offer("app", .application)]
        )
    }

    func testAccessoryInstancesNeedConfirmedWindows() {
        for resolution: ApplicationWindowResolution<String> in [
            .application,
            .windowless,
        ] {
            XCTAssertEqual(
                offers(
                    [instance("menu", processIdentifier: 1, policy: .windowsOnly)],
                    [1: resolution]
                ),
                []
            )
        }
        XCTAssertEqual(
            offers(
                [instance("menu", processIdentifier: 1, policy: .windowsOnly)],
                [:]
            ),
            []
        )

        for resolution: ApplicationWindowResolution<String> in [
            .singleWindow("A"),
            .windows(["M"]),
        ] {
            XCTAssertEqual(
                offers(
                    [instance("menu", processIdentifier: 1, policy: .windowsOnly)],
                    [1: resolution]
                ),
                [offer("menu", resolution)]
            )
        }
    }

    func testKeepsTheOrderOfApplications() {
        XCTAssertEqual(
            offers(
                [
                    instance("mail", processIdentifier: 1),
                    instance("A", applicationIdentifier: "firefox", processIdentifier: 2),
                    instance("B", applicationIdentifier: "firefox", processIdentifier: 3),
                    instance("notes", processIdentifier: 4),
                ],
                [2: .singleWindow("a1"), 3: .singleWindow("b1")]
            ),
            [
                offer("mail", .application),
                offer("A", .windows(["a1"])),
                offer("B", .windows(["b1"])),
                offer("notes", .application),
            ]
        )
    }

    private func offers(
        _ instances: [ApplicationInstance<String>],
        _ resolutions: [Int32: ApplicationWindowResolution<String>]
    ) -> [ApplicationOffer<String, String>] {
        ApplicationTargetPlan.offers(for: instances, resolutions: resolutions)
    }

    private func offer(
        _ item: String,
        _ resolution: ApplicationWindowResolution<String>
    ) -> ApplicationOffer<String, String> {
        ApplicationOffer(item: item, resolution: resolution)
    }
}

private func instance(
    _ item: String,
    applicationIdentifier: String? = nil,
    name: String? = nil,
    processIdentifier: Int32,
    policy: ApplicationDiscoveryPolicy = .regular
) -> ApplicationInstance<String> {
    ApplicationInstance(
        item: item,
        applicationIdentifier: applicationIdentifier ?? item,
        name: name ?? item,
        processIdentifier: processIdentifier,
        policy: policy
    )
}
