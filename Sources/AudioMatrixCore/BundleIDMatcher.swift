import Foundation

public enum BundleIDMatcher {
    /// Returns the parent bundle ID for helper processes (e.g. Chrome helpers).
    public static func parentBundleID(of bundleID: String) -> String {
        if bundleID.hasSuffix(".helper") {
            if let range = bundleID.range(of: ".helper") {
                return String(bundleID[..<range.lowerBound])
            }
        }

        let components = bundleID.split(separator: ".")
        if components.count > 3,
           let last = components.last,
           ["helper", "Helper", "plugin", "Plugin", "renderer", "Renderer", "gpu", "GPU"]
            .contains(String(last)) {
            return components.dropLast().joined(separator: ".")
        }

        return bundleID
    }

    public static func matches(requestedBundleID: String, candidateBundleID: String) -> Bool {
        let requestedParent = parentBundleID(of: requestedBundleID)
        let candidateParent = parentBundleID(of: candidateBundleID)
        if requestedParent == candidateParent {
            return true
        }
        return requestedBundleID == candidateBundleID
    }
}
