import ApplicationServices

enum AXElementReader {
    static func values(
        of attributes: [String],
        from element: AXUIElement
    ) -> [Any]? {
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        ) == .success,
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
