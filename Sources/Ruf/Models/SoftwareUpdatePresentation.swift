import RufCore

extension SoftwareUpdateAvailability {
    var actionTitle: String {
        availableVersion.map {
            "Update Ruf to \($0)…"
        } ?? "Check for Updates…"
    }
}
