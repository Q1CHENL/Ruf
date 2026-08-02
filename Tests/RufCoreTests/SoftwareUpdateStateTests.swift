import Testing
@testable import RufCore

struct SoftwareUpdateStateTests {
    @Test
    func primaryActionFollowsUpdateProgress() {
        #expect(SoftwareUpdateState.idle.primaryAction == .check)
        #expect(
            SoftwareUpdateState.available(version: "0.2.0").primaryAction
                == .download
        )
        #expect(
            SoftwareUpdateState.readyToInstall(version: "0.2.0").primaryAction
                == .installAndRelaunch
        )
    }

    @Test
    func workInProgressCannotBeStartedTwice() {
        #expect(SoftwareUpdateState.checking.primaryAction == nil)
        #expect(
            SoftwareUpdateState.downloading(version: "0.2.0").primaryAction
                == nil
        )
        #expect(
            SoftwareUpdateState.installing(version: "0.2.0").primaryAction
                == nil
        )
    }
}
