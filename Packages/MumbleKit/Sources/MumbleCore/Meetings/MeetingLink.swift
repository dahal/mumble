import Foundation

/// Recognizes meeting apps and meeting links, so Mumble can notice a call starting and match it
/// to a calendar event.
public enum MeetingLink {
    /// Native meeting apps by bundle ID prefix. Browser meetings are recognized by URL instead.
    public static let appBundles: [(prefix: String, app: MeetingApp)] = [
        ("us.zoom.xos", .zoom),
        ("com.microsoft.teams", .teams),
        ("com.tinyspeck.slackmacgap", .slack),
        ("com.cisco.webexmeetingsapp", .webex),
        ("Cisco-Systems.Spark", .webex),
        ("com.apple.FaceTime", .facetime),
    ]

    /// Browsers whose tabs may hold a meeting.
    public static let browserBundles: [String] = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    public static func app(forBundleID bundleID: String) -> MeetingApp? {
        appBundles.first { bundleID.hasPrefix($0.prefix) }?.app
    }

    public static func isBrowser(_ bundleID: String) -> Bool {
        browserBundles.contains { bundleID.hasPrefix($0) }
    }

    /// The meeting app a URL belongs to, if it is an actual meeting (not a landing page).
    public static func app(forURL string: String) -> MeetingApp? {
        guard let url = URL(string: string.contains("://") ? string : "https://" + string),
              let host = url.host?.lowercased()
        else { return nil }
        let path = url.path
        if host == "meet.google.com" {
            // Meeting codes look like abc-defg-hij; "/landing", "/new" and the root are not meetings.
            let code = path.split(separator: "/").first.map(String.init) ?? ""
            return code.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil ? .meet : nil
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.hasPrefix("/j/") || path.hasPrefix("/wc/") || path.hasPrefix("/my/") ? .zoom : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft" {
            return path.contains("meetup-join") || path.contains("/meet/") || path.hasPrefix("/v2") ? .teams : nil
        }
        if host == "app.slack.com" { return path.contains("/huddle/") ? .slack : nil }
        if host.hasSuffix(".webex.com") { return path.contains("/meet/") || path.contains("/j.php") ? .webex : nil }
        return nil
    }

    /// Finds the first meeting link in free text (calendar location or notes).
    public static func firstLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url?.absoluteString, app(forURL: url) != nil { return url }
        }
        return nil
    }

    /// Canonical form for comparing links: lowercase host and path, no scheme, query, fragment or trailing slash.
    /// Zoom keeps its meeting ID; Google Meet keeps its code.
    public static func normalize(_ string: String) -> String {
        guard let url = URL(string: string.contains("://") ? string : "https://" + string),
              let host = url.host?.lowercased()
        else { return string.lowercased() }
        var path = url.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        // Zoom's vanity subdomains and the web client point at the same meeting ID.
        if host.hasSuffix("zoom.us"), let id = path.split(separator: "/").last(where: { $0.allSatisfy(\.isNumber) }) {
            return "zoom.us/j/\(id)"
        }
        return host + path
    }
}
