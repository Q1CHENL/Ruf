public enum SoftwareUpdateAction: Equatable, Sendable {
    case check
    case download
    case installAndRelaunch
}

public enum SoftwareUpdateState: Equatable, Sendable {
    case idle
    case checking
    case available(version: String)
    case downloading(version: String)
    case readyToInstall(version: String)
    case installing(version: String)

    public var primaryAction: SoftwareUpdateAction? {
        switch self {
        case .idle:
            .check
        case .available:
            .download
        case .readyToInstall:
            .installAndRelaunch
        case .checking, .downloading, .installing:
            nil
        }
    }
}
