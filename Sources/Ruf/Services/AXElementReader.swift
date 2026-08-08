import ApplicationServices

enum AXElementReader {
    static func values(
        of attributes: [String],
        from element: AXUIElement
    ) -> [Any]? {
        let (error, rawValues) = AXClientContext.withDefaultIdentity {
            var rawValues: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(
                element,
                attributes as CFArray,
                [],
                &rawValues
            )
            return (error, rawValues)
        }

        guard error == .success,
              let rawValues,
              let values = rawValues as? [Any],
              values.count == attributes.count else {
            return nil
        }

        return values
    }

    static func decoded<Value>(_ value: Any) -> Value? {
        let rawValue = value as CFTypeRef
        guard CFGetTypeID(rawValue) != AXValueGetTypeID() else {
            return nil
        }

        return rawValue as? Value
    }

    static func decodedAXValue<Value: BitwiseCopyable>(
        _ value: Any,
        type: AXValueType,
        initialValue: Value
    ) -> Value? {
        let rawValue = value as CFTypeRef
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == type else {
            return nil
        }

        var decodedValue = initialValue
        return AXValueGetValue(axValue, type, &decodedValue)
            ? decodedValue
            : nil
    }

    static func error(from value: Any) -> AXError? {
        decodedAXValue(
            value,
            type: .axError,
            initialValue: AXError.success
        )
    }

    static func containsTransientError(in values: [Any]) -> Bool {
        values.contains { value in
            guard let error = error(from: value) else {
                return false
            }

            switch error {
            case .attributeUnsupported, .noValue:
                return false
            default:
                return true
            }
        }
    }
}
