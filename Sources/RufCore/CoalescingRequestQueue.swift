public struct CoalescingRequestQueue<
    Request: Sendable,
    Key: Hashable & Sendable
>: Sendable {
    private struct PendingRequest: Sendable {
        let coalescingKey: Key?
        var value: Request
    }

    private var isProcessing = false
    private var pendingRequests: [PendingRequest] = []

    public init() {}

    public mutating func submit(
        _ request: Request,
        coalescingKey: Key?
    ) -> Request? {
        guard isProcessing else {
            isProcessing = true
            return request
        }

        if let coalescingKey,
           pendingRequests.last?.coalescingKey == coalescingKey {
            pendingRequests[pendingRequests.count - 1].value = request
        } else {
            pendingRequests.append(
                PendingRequest(
                    coalescingKey: coalescingKey,
                    value: request
                )
            )
        }

        return nil
    }

    public mutating func removePendingRequests(coalescingKey: Key) {
        pendingRequests.removeAll {
            $0.coalescingKey == coalescingKey
        }
    }

    public mutating func completeCurrentRequest() -> Request? {
        guard !pendingRequests.isEmpty else {
            isProcessing = false
            return nil
        }

        return pendingRequests.removeFirst().value
    }
}
