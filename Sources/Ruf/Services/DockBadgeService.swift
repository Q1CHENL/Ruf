import AppKit
import ApplicationServices
import RufCore

enum DockBadgeService {
    private static let dockBundleIdentifier = "com.apple.dock"
    private static let statusLabelAttribute = "AXStatusLabel"
    private static let messageTimeout: Float = 0.05
    // The switcher must never wait on a slow Dock AX tree. Normal reads finish
    // in a few milliseconds; this only bounds degraded system states.
    private static let queryBudget = DispatchTimeInterval.milliseconds(100)

    @MainActor
    static func badges() async -> [URL: DockBadge] {
        guard AccessibilityPermission.isGranted,
              let dockProcessIdentifier = NSWorkspace.shared.runningApplications
                  .first(where: {
                      $0.bundleIdentifier == dockBundleIdentifier
                  })?
                  .processIdentifier else {
            return [:]
        }

        let queryTask = Task.detached(priority: .userInitiated) {
            queryBadges(for: dockProcessIdentifier)
        }

        return await withTaskCancellationHandler {
            await queryTask.value
        } onCancel: {
            queryTask.cancel()
        }
    }

    private static func queryBadges(
        for dockProcessIdentifier: pid_t
    ) -> [URL: DockBadge] {
        let badgeSpan = PerformanceLog.begin("ax.dockBadges")
        defer {
            PerformanceLog.end(badgeSpan)
        }

        let deadline = DispatchTime.now() + queryBudget
        let dockElement = AXClientContext.applicationElement(
            for: dockProcessIdentifier
        )
        AXClientContext.setMessagingTimeout(messageTimeout, for: dockElement)

        guard !Task.isCancelled,
              let rootValues = AXElementReader.values(
                  of: [kAXChildrenAttribute],
                  from: dockElement
              ),
              let rootChildren: [AXUIElement] = AXElementReader.decoded(
                  rootValues[0]
              ),
              let dockItems = dockItems(
                  in: rootChildren,
                  deadline: deadline
              ) else {
            return [:]
        }

        var badges: [URL: DockBadge] = [:]

        for dockItem in dockItems {
            guard !Task.isCancelled,
                  DispatchTime.now() < deadline else {
                break
            }

            AXClientContext.setMessagingTimeout(messageTimeout, for: dockItem)
            guard let values = AXElementReader.values(
                of: [
                    kAXSubroleAttribute,
                    kAXIsApplicationRunningAttribute,
                    kAXURLAttribute,
                    statusLabelAttribute,
                ],
                from: dockItem
            ) else {
                continue
            }

            let subrole: String? = AXElementReader.decoded(values[0])
            let isRunning: Bool = AXElementReader.decoded(values[1]) ?? false
            let applicationURL: URL? = AXElementReader.decoded(values[2])
            let statusLabel: String? = AXElementReader.decoded(values[3])

            guard subrole == kAXApplicationDockItemSubrole,
                  isRunning,
                  let applicationURL,
                  let badge = DockBadge(statusLabel: statusLabel) else {
                continue
            }

            badges[applicationURL.standardizedFileURL] = badge
        }

        return badges
    }

    private static func dockItems(
        in rootChildren: [AXUIElement],
        deadline: DispatchTime
    ) -> [AXUIElement]? {
        for child in rootChildren {
            guard !Task.isCancelled,
                  DispatchTime.now() < deadline else {
                return nil
            }

            AXClientContext.setMessagingTimeout(messageTimeout, for: child)
            guard let values = AXElementReader.values(
                of: [kAXRoleAttribute, kAXChildrenAttribute],
                from: child
            ) else {
                continue
            }

            let role: String? = AXElementReader.decoded(values[0])
            guard role == kAXListRole else {
                continue
            }

            let children: [AXUIElement]? = AXElementReader.decoded(values[1])
            return children
        }

        return nil
    }
}
