import Foundation

// MARK: - HostBoundary

/// The hosts a tool kit lets the model reach over the network.
///
/// Matching is by DNS label, so `example.com` admits `example.com` and `api.example.com` but
/// not `notexample.com` or `example.com.evil.net`. Comparison is case-insensitive, because a
/// host name is.
///
/// Schemes other than `http` and `https` are refused whether or not a list is set: the only
/// thing the bridge's `fetch` is meant to do is retrieve a page, and every other scheme is a
/// way of asking a URL loader to do something else — read a local file, most obviously.
internal struct HostBoundary: Sendable {
    /// The allowed hosts, lowercased. `nil` imposes no boundary.
    let allowedHosts: [String]?

    init(allowedHosts: [String]?) {
        self.allowedHosts = allowedHosts?.map { $0.lowercased() }
    }

    /// Why this URL may not be fetched, or `nil` if it may.
    ///
    /// A question rather than an operation, because the caller is a JavaScriptCore block that
    /// cannot throw and has to turn the answer into a string either way.
    func violation(for url: URL) -> URLOutsideBoundary? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            return URLOutsideBoundary(reason: .unsupportedScheme(url.scheme ?? ""), allowedHosts: allowedHosts)
        }

        // No list means no boundary.
        guard let allowedHosts else { return nil }

        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return URLOutsideBoundary(reason: .hostNotAllowed(""), allowedHosts: allowedHosts)
        }

        let isAllowed = allowedHosts.contains { allowed in
            Self.isWithin(host, allowed: allowed)
        }

        guard isAllowed else {
            return URLOutsideBoundary(reason: .hostNotAllowed(host), allowedHosts: allowedHosts)
        }

        return nil
    }

    /// Whether `host` is `allowed` itself or a subdomain of it.
    ///
    /// The dot is part of the comparison, which is what separates a subdomain from a name that
    /// merely ends the same way. Both arguments must already be lowercased.
    static func isWithin(_ host: String, allowed: String) -> Bool {
        if host == allowed { return true }
        return host.hasSuffix("." + allowed)
    }
}

// MARK: - URLOutsideBoundary

/// A URL a script asked for that the boundary would not let through.
internal struct URLOutsideBoundary: Error {
    enum Reason {
        case unsupportedScheme(String)
        case hostNotAllowed(String)
    }

    let reason: Reason
    let allowedHosts: [String]?
}
