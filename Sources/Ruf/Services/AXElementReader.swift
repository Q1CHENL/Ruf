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
}
