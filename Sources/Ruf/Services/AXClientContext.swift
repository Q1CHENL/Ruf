import ApplicationServices
import Darwin
@preconcurrency import Dispatch

enum AXClientContext {
    // Raw values from the private HIServices AXClientType enum. Zero clears
    // the process-wide override instead of leaving Ruf identified as an
    // assistive-technology client.
    private enum ClientType: Int32 {
        case noActiveRequestFound = 0
        case voiceOver = 7
    }

    private typealias SetClientIdentificationOverrideFunction =
        @convention(c) (Int32) -> Void

    private static let setClientIdentificationOverride:
        SetClientIdentificationOverrideFunction? = {
            // Resolve this private SPI at runtime so its removal disables only
            // this recovery path instead of preventing Ruf from launching.
            guard
                let processHandle = dlopen(nil, RTLD_LAZY),
                let symbol = dlsym(
                    processHandle,
                    "_AXSetClientIdentificationOverride"
                )
            else {
                return nil
            }

            return unsafeBitCast(
                symbol,
                to: SetClientIdentificationOverrideFunction.self
            )
        }()

    // The private override changes Ruf's process-wide AX identity, not only
    // the calling thread. Ordinary AX messages share this concurrent queue;
    // the override uses a barrier so no unrelated request observes it.
    private static let accessQueueKey = DispatchSpecificKey<Void>()
    private static let accessQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.qichen.ruf.ax-client-context",
            attributes: .concurrent
        )
        queue.setSpecific(key: accessQueueKey, value: ())
        return queue
    }()

    static func withDefaultIdentity<Result>(
        _ operation: () -> Result
    ) -> Result {
        if DispatchQueue.getSpecific(key: accessQueueKey) != nil {
            return operation()
        }
        return accessQueue.sync(execute: operation)
    }

    static func applicationElement(
        for processIdentifier: pid_t
    ) -> AXUIElement {
        withDefaultIdentity {
            AXUIElementCreateApplication(processIdentifier)
        }
    }

    static func setMessagingTimeout(
        _ timeout: Float,
        for element: AXUIElement
    ) {
        _ = withDefaultIdentity {
            AXUIElementSetMessagingTimeout(element, timeout)
        }
    }

    static func withVoiceOverIdentity<Result>(
        _ operation: () -> Result
    ) -> Result? {
        guard let setClientIdentificationOverride else {
            return nil
        }

        return accessQueue.sync(flags: .barrier) {
            setClientIdentificationOverride(ClientType.voiceOver.rawValue)
            defer {
                setClientIdentificationOverride(
                    ClientType.noActiveRequestFound.rawValue
                )
            }
            return operation()
        }
    }
}
