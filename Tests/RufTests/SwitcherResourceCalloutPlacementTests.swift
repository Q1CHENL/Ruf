import CoreGraphics
import XCTest

@testable import Ruf

final class SwitcherResourceCalloutPlacementTests: XCTestCase {
    func testCentersCellsInAnIncompleteLastRow() throws {
        let itemCount = 5
        let panelSize = SwitcherMetrics.panelSize(itemCount: itemCount)
        let panelFrame = CGRect(origin: CGPoint(x: 100, y: 100), size: panelSize)

        let frame = try XCTUnwrap(
            SwitcherResourceCalloutPlacement.cellFrame(
                selectedIndex: 4,
                itemCount: itemCount,
                panelFrame: panelFrame
            )
        )

        XCTAssertEqual(
            frame.minX,
            panelFrame.midX + SwitcherMetrics.horizontalSpacing / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            frame.maxY,
            panelFrame.maxY
                - SwitcherMetrics.containerInset
                - SwitcherMetrics.cellSize.height
                - SwitcherMetrics.verticalSpacing,
            accuracy: 0.001
        )
    }

    func testPlacesATopRowCalloutDirectlyAboveItsCell() throws {
        let itemCount = 5
        let panelSize = SwitcherMetrics.panelSize(itemCount: itemCount)
        let panelFrame = CGRect(origin: CGPoint(x: 400, y: 300), size: panelSize)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
        let cellFrame = try XCTUnwrap(
            SwitcherResourceCalloutPlacement.cellFrame(
                selectedIndex: 1,
                itemCount: itemCount,
                panelFrame: panelFrame
            )
        )

        let placement = try XCTUnwrap(
            SwitcherResourceCalloutPlacement.resolve(
                selectedIndex: 1,
                itemCount: itemCount,
                panelFrame: panelFrame,
                visibleFrame: visibleFrame
            )
        )

        XCTAssertEqual(
            placement.frame.minY,
            cellFrame.maxY + SwitcherResourceCalloutMetrics.gap,
            accuracy: 0.001
        )
        XCTAssertEqual(
            placement.frame.midX,
            cellFrame.midX,
            accuracy: 0.001
        )
    }

    func testKeepsAnInteriorRowCalloutDirectlyAboveItsCell() throws {
        let itemCount = 9
        let panelSize = SwitcherMetrics.panelSize(itemCount: itemCount)
        let panelFrame = CGRect(origin: CGPoint(x: 500, y: 300), size: panelSize)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let cellFrame = try XCTUnwrap(
            SwitcherResourceCalloutPlacement.cellFrame(
                selectedIndex: 4,
                itemCount: itemCount,
                panelFrame: panelFrame
            )
        )

        let placement = try XCTUnwrap(
            SwitcherResourceCalloutPlacement.resolve(
                selectedIndex: 4,
                itemCount: itemCount,
                panelFrame: panelFrame,
                visibleFrame: visibleFrame
            )
        )

        XCTAssertEqual(
            placement.frame.minY,
            cellFrame.maxY + SwitcherResourceCalloutMetrics.gap,
            accuracy: 0.001
        )
        XCTAssertEqual(
            placement.frame.midX,
            cellFrame.midX,
            accuracy: 0.001
        )
        XCTAssertTrue(placement.frame.intersects(panelFrame))
    }

    func testKeepsABottomRowCalloutDirectlyAboveItsCell() throws {
        let itemCount = 5
        let panelSize = SwitcherMetrics.panelSize(itemCount: itemCount)
        let panelFrame = CGRect(origin: CGPoint(x: 400, y: 300), size: panelSize)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
        let cellFrame = try XCTUnwrap(
            SwitcherResourceCalloutPlacement.cellFrame(
                selectedIndex: 4,
                itemCount: itemCount,
                panelFrame: panelFrame
            )
        )

        let placement = try XCTUnwrap(
            SwitcherResourceCalloutPlacement.resolve(
                selectedIndex: 4,
                itemCount: itemCount,
                panelFrame: panelFrame,
                visibleFrame: visibleFrame
            )
        )

        XCTAssertEqual(
            placement.frame.minY,
            cellFrame.maxY + SwitcherResourceCalloutMetrics.gap,
            accuracy: 0.001
        )
    }

    func testKeepsThePillOnScreenWithoutMovingItToAnotherPanelEdge() throws {
        let itemCount = 9
        let panelSize = SwitcherMetrics.panelSize(itemCount: itemCount)
        let panelFrame = CGRect(origin: CGPoint(x: 8, y: 300), size: panelSize)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)

        let placement = try XCTUnwrap(
            SwitcherResourceCalloutPlacement.resolve(
                selectedIndex: 3,
                itemCount: itemCount,
                panelFrame: panelFrame,
                visibleFrame: visibleFrame
            )
        )

        XCTAssertEqual(
            placement.frame.minX,
            visibleFrame.minX,
            accuracy: 0.001
        )
    }
}
